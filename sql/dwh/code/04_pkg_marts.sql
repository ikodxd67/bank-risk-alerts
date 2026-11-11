CREATE OR REPLACE PACKAGE pkg_marts AS
    -- Обороты дня по каналам и странам.
    PROCEDURE build_turnover(p_date IN DATE);

    -- Признаки операций дня (окна 1 ч / 24 ч / 30 дней по карте), срабатывания
    -- правил из fraud_rule и свежие жалобы в fraud_label.
    PROCEDURE build_fraud(p_date IN DATE);

    -- Снимок просрочки на конец дня по каждому действующему кредиту.
    PROCEDURE build_dpd(p_date IN DATE);

    -- Ежедневный запуск всех витрин. Вызывать после pkg_dds.run_day за ту же дату.
    PROCEDURE run_day(p_date IN DATE);
END pkg_marts;
/

CREATE OR REPLACE PACKAGE BODY pkg_marts AS

    PROCEDURE build_turnover(p_date IN DATE) IS
        l_log  NUMBER := pkg_log.start_step('build_turnover', p_date);
        l_rows NUMBER;
    BEGIN
        DELETE FROM mart_daily_turnover WHERE report_date = p_date;
        INSERT INTO mart_daily_turnover (report_date, channel, is_foreign, trx_cnt, declined_cnt,
                                         approved_amount, card_cnt)
        SELECT trx_date, channel, CASE WHEN country = 'KZ' THEN 'N' ELSE 'Y' END,
               COUNT(*),
               COUNT(CASE WHEN status = 'DECLINED' THEN 1 END),
               NVL(SUM(CASE WHEN status = 'APPROVED' THEN amount END), 0),
               COUNT(DISTINCT card_id)
        FROM fct_transactions
        WHERE trx_date = p_date
        GROUP BY trx_date, channel, CASE WHEN country = 'KZ' THEN 'N' ELSE 'Y' END;
        l_rows := SQL%ROWCOUNT;
        COMMIT;
        pkg_log.ok(l_log, l_rows);
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_log.fail(l_log, SQLERRM || CHR(10) || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
            RAISE;
    END build_turnover;

    PROCEDURE build_fraud(p_date IN DATE) IS
        l_log  NUMBER := pkg_log.start_step('build_fraud', p_date);
        l_rows NUMBER;
    BEGIN
        -- 1. Признаки. Окна считаем по 31 дню факта (30 дней истории + сам день),
        --    а сохраняем только строки дня. Предикат по trx_date отсекает партиции.
        DELETE FROM mart_trx_features WHERE trx_date = p_date;
        INSERT INTO mart_trx_features (trx_id, trx_date, trx_ts, card_id, client_id, amount, channel, country,
                                       online_cnt_1h, trx_cnt_24h, purchase_cnt_30d, avg_purchase_30d,
                                       device_seen_30d, prev_country, minutes_since_prev)
        SELECT trx_id, trx_date, trx_ts, card_id, client_id, amount, channel, country,
               online_cnt_1h, trx_cnt_24h, purchase_cnt_30d, avg_purchase_30d,
               device_seen_30d, prev_country, minutes_since_prev
        FROM (
            SELECT f.*,
                   COUNT(CASE WHEN f.channel = 'ONLINE' THEN 1 END) OVER (
                       PARTITION BY f.card_id ORDER BY f.trx_ts
                       RANGE BETWEEN INTERVAL '1' HOUR PRECEDING AND CURRENT ROW) AS online_cnt_1h,
                   COUNT(*) OVER (
                       PARTITION BY f.card_id ORDER BY f.trx_ts
                       RANGE BETWEEN INTERVAL '1' DAY PRECEDING AND CURRENT ROW) AS trx_cnt_24h,
                   -- история «до» операции: сама операция в среднее не входит.
                   -- Только одобренные покупки: снятие в банкомате крупнее покупки и портит среднее.
                   COUNT(CASE WHEN f.status = 'APPROVED' AND f.channel <> 'ATM' THEN 1 END) OVER (
                       PARTITION BY f.card_id ORDER BY f.trx_ts
                       RANGE BETWEEN INTERVAL '30' DAY PRECEDING AND INTERVAL '1' SECOND PRECEDING) AS purchase_cnt_30d,
                   ROUND(AVG(CASE WHEN f.status = 'APPROVED' AND f.channel <> 'ATM' THEN f.amount END) OVER (
                       PARTITION BY f.card_id ORDER BY f.trx_ts
                       RANGE BETWEEN INTERVAL '30' DAY PRECEDING AND INTERVAL '1' SECOND PRECEDING), 2) AS avg_purchase_30d,
                   -- устройство «знакомое», если по карте с него платили раньше чем за час до операции:
                   -- иначе вторая операция мошенника с того же устройства его уже «знает»
                   COUNT(*) OVER (
                       PARTITION BY f.card_id, f.device_id ORDER BY f.trx_ts
                       RANGE BETWEEN INTERVAL '30' DAY PRECEDING AND INTERVAL '1' HOUR PRECEDING) AS device_seen_30d,
                   LAG(f.country) OVER (PARTITION BY f.card_id ORDER BY f.trx_ts, f.trx_id) AS prev_country,
                   ROUND((CAST(f.trx_ts AS DATE)
                          - CAST(LAG(f.trx_ts) OVER (PARTITION BY f.card_id ORDER BY f.trx_ts, f.trx_id) AS DATE))
                         * 24 * 60) AS minutes_since_prev
            FROM fct_transactions f
            WHERE f.trx_date BETWEEN p_date - 30 AND p_date
        )
        WHERE trx_date = p_date;

        -- 2. Срабатывания. Порог берём из fraud_rule на момент сборки и сохраняем рядом.
        DELETE FROM fraud_alert WHERE alert_date = p_date;
        INSERT INTO fraud_alert (alert_date, trx_id, rule_code, card_id, client_id, trx_ts, amount, value, threshold)
        SELECT alert_date, trx_id, rule_code, card_id, client_id, trx_ts, amount, value, threshold
        FROM (
            SELECT f.trx_date AS alert_date, f.trx_id, r.rule_code, f.card_id, f.client_id, f.trx_ts, f.amount,
                   r.threshold,
                   CASE r.rule_code
                       WHEN 'VELOCITY_1H' THEN
                           CASE WHEN f.channel = 'ONLINE' AND f.online_cnt_1h >= r.threshold
                                THEN f.online_cnt_1h END
                       WHEN 'AMOUNT_30D' THEN
                           CASE WHEN f.channel <> 'ATM' AND f.purchase_cnt_30d >= r.min_history
                                 AND f.amount >= r.threshold * f.avg_purchase_30d
                                THEN ROUND(f.amount / f.avg_purchase_30d, 1) END
                       WHEN 'GEO_SWITCH' THEN
                           CASE WHEN f.channel = 'POS' AND f.country <> 'KZ' AND f.prev_country = 'KZ'
                                 AND f.minutes_since_prev <= r.threshold
                                THEN f.minutes_since_prev END
                       WHEN 'NIGHT_P2P_NEW_DEVICE' THEN
                           -- истории нет — среднее NULL, считаем его нулём (value = 0): ночной
                           -- перевод с нового устройства по «пустой» карте подозрителен сам по себе
                           CASE WHEN f.channel = 'P2P' AND EXTRACT(HOUR FROM f.trx_ts) < 6
                                 AND f.device_seen_30d = 0
                                 AND f.amount >= r.threshold * NVL(f.avg_purchase_30d, 0)
                                THEN NVL(ROUND(f.amount / NULLIF(f.avg_purchase_30d, 0), 1), 0) END
                   END AS value
            FROM mart_trx_features f
            CROSS JOIN fraud_rule r
            WHERE f.trx_date = p_date AND r.is_active = 'Y'
        )
        WHERE value IS NOT NULL;
        l_rows := SQL%ROWCOUNT;

        -- 3. Жалобы приходят с опозданием на любые прошлые дни — забираем все новые.
        MERGE INTO fraud_label l
        USING src.fraud_reports s
        ON (l.trx_id = s.trx_id)
        WHEN MATCHED THEN UPDATE SET l.reported_at = s.reported_at, l.fraud_type = s.fraud_type
            WHERE l.reported_at <> s.reported_at OR l.fraud_type <> s.fraud_type
        WHEN NOT MATCHED THEN INSERT (trx_id, reported_at, fraud_type)
            VALUES (s.trx_id, s.reported_at, s.fraud_type);

        COMMIT;
        pkg_log.ok(l_log, l_rows);
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_log.fail(l_log, SQLERRM || CHR(10) || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
            RAISE;
    END build_fraud;

    PROCEDURE build_dpd(p_date IN DATE) IS
        l_log  NUMBER := pkg_log.start_step('build_dpd', p_date);
        l_rows NUMBER;
    BEGIN
        -- Платежи гасят взносы по порядку. Первый взнос, который не покрыт суммой
        -- всех платежей на дату, и есть начало просрочки: dpd = p_date - его дата.
        DELETE FROM mart_loan_dpd WHERE snapshot_date = p_date;
        INSERT INTO mart_loan_dpd (snapshot_date, loan_id, client_id, principal, due_cnt, due_total,
                                   paid_total, dpd, bucket)
        WITH paid AS (
            SELECT loan_id, SUM(amount) AS paid_total
            FROM fct_loan_payment
            WHERE paid_on <= p_date
            GROUP BY loan_id
        ), loans AS (
            SELECT l.loan_id, l.client_id, l.principal, NVL(p.paid_total, 0) AS paid_total,
                   (SELECT COUNT(*) FROM loan_schedule s
                    WHERE s.loan_id = l.loan_id AND s.due_date <= p_date) AS due_cnt,
                   (SELECT NVL(SUM(s.amount), 0) FROM loan_schedule s
                    WHERE s.loan_id = l.loan_id AND s.due_date <= p_date) AS due_total,
                   (SELECT MIN(s.due_date) FROM loan_schedule s
                    WHERE s.loan_id = l.loan_id AND s.due_date <= p_date
                      AND s.installment_no * s.amount > NVL(p.paid_total, 0)) AS first_unpaid,
                   (SELECT SUM(s.amount) FROM loan_schedule s WHERE s.loan_id = l.loan_id) AS total
            FROM dim_loan l
            LEFT JOIN paid p ON p.loan_id = l.loan_id
            WHERE l.issued_on <= p_date
        )
        SELECT p_date, loan_id, client_id, principal, due_cnt, due_total, paid_total, dpd,
               CASE WHEN dpd = 0 THEN '0'
                    WHEN dpd <= 30 THEN '1-30'
                    WHEN dpd <= 60 THEN '31-60'
                    WHEN dpd <= 90 THEN '61-90'
                    ELSE '90+' END
        FROM (SELECT l.*, NVL(p_date - first_unpaid, 0) AS dpd FROM loans l)
        WHERE paid_total < total;   -- погашенные кредиты в снимок не попадают
        l_rows := SQL%ROWCOUNT;
        COMMIT;
        pkg_log.ok(l_log, l_rows);
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            pkg_log.fail(l_log, SQLERRM || CHR(10) || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
            RAISE;
    END build_dpd;

    PROCEDURE run_day(p_date IN DATE) IS
    BEGIN
        IF p_date IS NULL OR p_date <> TRUNC(p_date) THEN
            RAISE_APPLICATION_ERROR(-20001, 'нужна дата без времени');
        END IF;
        build_turnover(p_date);
        build_fraud(p_date);
        build_dpd(p_date);
    END run_day;

END pkg_marts;
/
