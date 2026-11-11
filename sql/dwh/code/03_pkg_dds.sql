CREATE OR REPLACE PACKAGE pkg_dds AS
    -- Измерения на дату p_date: продавцы, карты, кредиты (SCD1) и график новых
    -- кредитов, клиенты (SCD2) — состояние клиента на p_date из журнала
    -- src.client_history. Только вперёд: дата раньше последней версии — ошибка -20002.
    PROCEDURE load_dims(p_date IN DATE);

    -- Операции одного дня: DELETE + INSERT в одной транзакции (идемпотентно).
    PROCEDURE load_transactions(p_date IN DATE);

    -- Платежи по кредитам за день: так же, DELETE + INSERT.
    PROCEDURE load_payments(p_date IN DATE);

    -- Ежедневный запуск: измерения, операции, платежи.
    PROCEDURE run_day(p_date IN DATE);

    -- Пересборка месяца целиком через обмен партиций: данные собираются в
    -- отдельной таблице, потом подменяют партицию одной операцией словаря.
    PROCEDURE reload_month(p_month IN DATE);

    -- Пересобрать dim_client по журналу до p_to включительно и перевязать факт
    -- на новые версии (reload_month по всем месяцам). Ремонтная процедура: DAG на паузу.
    PROCEDURE rebuild_clients(p_to IN DATE);
END pkg_dds;
/

CREATE OR REPLACE PACKAGE BODY pkg_dds AS

    c_open  CONSTANT DATE := DATE '9999-12-31';
    c_first CONSTANT DATE := DATE '1900-01-01';

    PROCEDURE check_date(p_date IN DATE) IS
    BEGIN
        IF p_date IS NULL OR p_date <> TRUNC(p_date) THEN
            RAISE_APPLICATION_ERROR(-20001, 'нужна дата без времени, пришло: '
                || NVL(TO_CHAR(p_date, 'YYYY-MM-DD HH24:MI:SS'), 'NULL'));
        END IF;
    END check_date;

    PROCEDURE load_dims(p_date IN DATE) IS
        l_log  NUMBER := pkg_log.start_step('load_dims', p_date);
        l_rows NUMBER := 0;
        l_last DATE;
    BEGIN
        check_date(p_date);

        SELECT MAX(valid_from) INTO l_last FROM dim_client;   -- пустая таблица → NULL, без NO_DATA_FOUND
        IF p_date < l_last THEN
            RAISE_APPLICATION_ERROR(-20002, 'измерения грузятся только вперёд: последняя версия '
                || TO_CHAR(l_last, 'YYYY-MM-DD') || ', пришло ' || TO_CHAR(p_date, 'YYYY-MM-DD'));
        END IF;

        MERGE INTO dim_merchant d
        USING src.merchants s
        ON (d.merchant_id = s.merchant_id)
        WHEN MATCHED THEN UPDATE
            SET d.name = s.name, d.mcc = s.mcc, d.country = s.country
            WHERE d.name <> s.name OR d.mcc <> s.mcc OR d.country <> s.country
        WHEN NOT MATCHED THEN INSERT (merchant_id, name, mcc, country)
            VALUES (s.merchant_id, s.name, s.mcc, s.country);
        l_rows := l_rows + SQL%ROWCOUNT;

        MERGE INTO dim_card d
        USING src.cards s
        ON (d.card_id = s.card_id)
        WHEN MATCHED THEN UPDATE
            SET d.client_id = s.client_id, d.card_type = s.card_type, d.opened_at = s.opened_at
            WHERE d.client_id <> s.client_id OR d.card_type <> s.card_type OR d.opened_at <> s.opened_at
        WHEN NOT MATCHED THEN INSERT (card_id, client_id, card_type, opened_at)
            VALUES (s.card_id, s.client_id, s.card_type, s.opened_at);
        l_rows := l_rows + SQL%ROWCOUNT;

        MERGE INTO dim_loan d
        USING src.loans s
        ON (d.loan_id = s.loan_id)
        WHEN MATCHED THEN UPDATE
            SET d.client_id = s.client_id, d.issued_on = s.issued_on, d.principal = s.principal,
                d.term_months = s.term_months, d.monthly_payment = s.monthly_payment
            WHERE d.client_id <> s.client_id OR d.issued_on <> s.issued_on OR d.principal <> s.principal
               OR d.term_months <> s.term_months OR d.monthly_payment <> s.monthly_payment
        WHEN NOT MATCHED THEN INSERT (loan_id, client_id, issued_on, principal, term_months, monthly_payment)
            VALUES (s.loan_id, s.client_id, s.issued_on, s.principal, s.term_months, s.monthly_payment);
        l_rows := l_rows + SQL%ROWCOUNT;

        -- График строится один раз на новый кредит. Взнос k — в тот же день через k
        -- месяцев, в коротком месяце — в последний день. ADD_MONTHS от самого дня
        -- выдачи не годится: от 28 февраля он даёт 31 марта.
        -- shortcut: условия договора считаются неизменными; изменятся — график не пересчитается.
        INSERT INTO loan_schedule (loan_id, installment_no, due_date, amount)
        SELECT l.loan_id, n.k,
               LEAST(ADD_MONTHS(TRUNC(l.issued_on, 'MM'), n.k) + (EXTRACT(DAY FROM l.issued_on) - 1),
                     LAST_DAY(ADD_MONTHS(TRUNC(l.issued_on, 'MM'), n.k))),
               l.monthly_payment
        FROM dim_loan l
        JOIN (SELECT LEVEL AS k FROM dual CONNECT BY LEVEL <= 600) n ON n.k <= l.term_months
        WHERE NOT EXISTS (SELECT 1 FROM loan_schedule s WHERE s.loan_id = l.loan_id);
        l_rows := l_rows + SQL%ROWCOUNT;

        -- SCD2, шаг 1. Версия уже открыта сегодня (второе изменение за день) —
        -- правим её на месте, иначе получится версия нулевой длины.
        MERGE INTO dim_client d
        USING (SELECT * FROM v_client_asof WHERE p_date >= state_from AND p_date < state_to) s
        ON (d.client_id = s.client_id AND d.valid_to = c_open AND d.valid_from = p_date)
        WHEN MATCHED THEN UPDATE
            SET d.full_name = s.full_name, d.birth_date = s.birth_date,
                d.city = s.city, d.segment = s.segment
            WHERE d.full_name <> s.full_name OR d.birth_date <> s.birth_date
               OR d.city <> s.city OR d.segment <> s.segment;
        l_rows := l_rows + SQL%ROWCOUNT;

        -- Шаг 2. Закрываем открытые версии, у которых в источнике другие значения.
        -- updated_at не сравниваем: «обновили, но ничего не поменяли» — не новая версия.
        UPDATE dim_client d
        SET d.valid_to = p_date
        WHERE d.valid_to = c_open
          AND d.valid_from < p_date
          AND EXISTS (
              SELECT 1 FROM (SELECT * FROM v_client_asof WHERE p_date >= state_from AND p_date < state_to) s
              WHERE s.client_id = d.client_id
                AND (s.full_name <> d.full_name OR s.birth_date <> d.birth_date
                     OR s.city <> d.city OR s.segment <> d.segment));
        l_rows := l_rows + SQL%ROWCOUNT;

        -- Шаг 3. Открываем версию всем, у кого открытой нет: новым клиентам и только что закрытым.
        INSERT INTO dim_client (client_id, full_name, birth_date, city, segment, valid_from, valid_to)
        SELECT s.client_id, s.full_name, s.birth_date, s.city, s.segment,
               CASE WHEN EXISTS (SELECT 1 FROM dim_client x WHERE x.client_id = s.client_id)
                    THEN p_date ELSE c_first END,
               c_open
        FROM (SELECT * FROM v_client_asof WHERE p_date >= state_from AND p_date < state_to) s
        WHERE NOT EXISTS (
            SELECT 1 FROM dim_client d WHERE d.client_id = s.client_id AND d.valid_to = c_open);
        l_rows := l_rows + SQL%ROWCOUNT;

        COMMIT;
        pkg_log.ok(l_log, l_rows);
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_log.fail(l_log, SQLERRM || CHR(10) || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
            RAISE;
    END load_dims;

    PROCEDURE load_transactions(p_date IN DATE) IS
        l_log  NUMBER := pkg_log.start_step('load_transactions', p_date);
        l_rows NUMBER;
    BEGIN
        check_date(p_date);

        DELETE FROM fct_transactions WHERE trx_date = p_date;

        INSERT INTO fct_transactions (trx_id, trx_ts, trx_date, card_id, client_id, client_sk,
                                      merchant_id, amount, channel, country, device_id, status)
        SELECT trx_id, trx_ts, trx_date, card_id, client_id, client_sk,
               merchant_id, amount, channel, country, device_id, status
        FROM v_trx_src
        WHERE trx_ts >= p_date AND trx_ts < p_date + 1;   -- диапазон, а не TRUNC(trx_ts) = p_date: работает индекс
        l_rows := SQL%ROWCOUNT;

        COMMIT;
        pkg_log.ok(l_log, l_rows);
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;   -- DELETE откатывается вместе с INSERT: день остаётся как был
            pkg_log.fail(l_log, SQLERRM || CHR(10) || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
            RAISE;
    END load_transactions;

    PROCEDURE load_payments(p_date IN DATE) IS
        l_log  NUMBER := pkg_log.start_step('load_payments', p_date);
        l_rows NUMBER;
    BEGIN
        check_date(p_date);

        DELETE FROM fct_loan_payment WHERE paid_on = p_date;
        INSERT INTO fct_loan_payment (payment_id, loan_id, paid_on, amount)
        SELECT payment_id, loan_id, paid_on, amount
        FROM src.loan_payments
        WHERE paid_on = p_date;
        l_rows := SQL%ROWCOUNT;

        COMMIT;
        pkg_log.ok(l_log, l_rows);
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_log.fail(l_log, SQLERRM || CHR(10) || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
            RAISE;
    END load_payments;

    PROCEDURE run_day(p_date IN DATE) IS
    BEGIN
        load_dims(p_date);
        load_transactions(p_date);
        load_payments(p_date);
    END run_day;

    PROCEDURE reload_month(p_month IN DATE) IS
        l_log   NUMBER := pkg_log.start_step('reload_month', p_month);
        l_from  DATE := TRUNC(p_month, 'MM');
        l_part  VARCHAR2(30) := 'DATE ''' || TO_CHAR(l_from, 'YYYY-MM-DD') || '''';
        l_rows  NUMBER;
    BEGIN
        check_date(p_month);

        -- Всё динамически: таблицы обмена нет на момент компиляции пакета.
        -- DDL в Oracle коммитит сам, поэтому порядок важен: собрать → обменять → убрать.
        EXECUTE IMMEDIATE 'DROP TABLE IF EXISTS fct_transactions_exch PURGE';
        EXECUTE IMMEDIATE 'CREATE TABLE fct_transactions_exch FOR EXCHANGE WITH TABLE fct_transactions';
        EXECUTE IMMEDIATE q'[
            INSERT /*+ APPEND */ INTO fct_transactions_exch
                (trx_id, trx_ts, trx_date, card_id, client_id, client_sk,
                 merchant_id, amount, channel, country, device_id, status, loaded_at)
            SELECT trx_id, trx_ts, trx_date, card_id, client_id, client_sk,
                   merchant_id, amount, channel, country, device_id, status, SYSTIMESTAMP
            FROM v_trx_src
            WHERE trx_ts >= :1 AND trx_ts < :2]'
            USING l_from, ADD_MONTHS(l_from, 1);
        l_rows := SQL%ROWCOUNT;
        COMMIT;

        -- interval-партиция появляется при первой записи; LOCK создаёт её, если месяца ещё нет
        EXECUTE IMMEDIATE 'LOCK TABLE fct_transactions PARTITION FOR (' || l_part || ') IN SHARE MODE';
        EXECUTE IMMEDIATE 'ALTER TABLE fct_transactions EXCHANGE PARTITION FOR (' || l_part
            || ') WITH TABLE fct_transactions_exch WITH VALIDATION';
        EXECUTE IMMEDIATE 'DROP TABLE fct_transactions_exch PURGE';

        pkg_log.ok(l_log, l_rows);
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_log.fail(l_log, SQLERRM || CHR(10) || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
            RAISE;
    END reload_month;

    PROCEDURE rebuild_clients(p_to IN DATE) IS
        l_log   NUMBER := pkg_log.start_step('rebuild_clients', p_to);
        l_first DATE;
    BEGIN
        check_date(p_to);
        DELETE FROM dim_client;
        COMMIT;
        -- Дни, когда клиент менялся (первая строка журнала — регистрация, не изменение).
        -- Достаточно прогнать load_dims только по ним: в остальные дни SCD2 ничего не делает.
        SELECT MIN(changed_at) - 1 INTO l_first
        FROM (SELECT changed_at, ROW_NUMBER() OVER (PARTITION BY client_id ORDER BY changed_at, hist_id) AS rn
              FROM src.client_history)
        WHERE rn > 1 AND changed_at <= p_to;
        load_dims(NVL(l_first, p_to));          -- все клиенты в состоянии до первого изменения
        FOR d IN (SELECT DISTINCT changed_at AS day
                  FROM (SELECT changed_at, ROW_NUMBER() OVER (PARTITION BY client_id ORDER BY changed_at, hist_id) AS rn
                        FROM src.client_history)
                  WHERE rn > 1 AND changed_at <= p_to
                  ORDER BY 1) LOOP
            load_dims(d.day);
        END LOOP;
        -- client_sk у всех версий новые — перевязываем весь факт
        FOR m IN (SELECT DISTINCT TRUNC(trx_date, 'MM') AS month FROM fct_transactions ORDER BY 1) LOOP
            reload_month(m.month);
        END LOOP;
        pkg_log.ok(l_log, NULL);
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_log.fail(l_log, SQLERRM || CHR(10) || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
            RAISE;
    END rebuild_clients;

END pkg_dds;
/
