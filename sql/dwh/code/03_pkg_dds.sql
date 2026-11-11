CREATE OR REPLACE PACKAGE pkg_dds AS
    -- Измерения на дату p_date: продавцы и карты (SCD1), клиенты (SCD2).
    -- Только вперёд: дата раньше последней версии клиента — ошибка -20002.
    PROCEDURE load_dims(p_date IN DATE);

    -- Операции одного дня: DELETE + INSERT в одной транзакции (идемпотентно).
    PROCEDURE load_transactions(p_date IN DATE);

    -- Ежедневный запуск: сначала измерения, потом операции.
    PROCEDURE run_day(p_date IN DATE);

    -- Пересборка месяца целиком через обмен партиций: данные собираются в
    -- отдельной таблице, потом подменяют партицию одной операцией словаря.
    PROCEDURE reload_month(p_month IN DATE);
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

        -- SCD2, шаг 1. Версия уже открыта сегодня (второе изменение за день) —
        -- правим её на месте, иначе получится версия нулевой длины.
        MERGE INTO dim_client d
        USING src.clients s
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
              SELECT 1 FROM src.clients s
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
        FROM src.clients s
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

    PROCEDURE run_day(p_date IN DATE) IS
    BEGIN
        load_dims(p_date);
        load_transactions(p_date);
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

END pkg_dds;
/
