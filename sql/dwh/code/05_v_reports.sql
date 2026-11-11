-- Отчётные представления поверх витрин: их читают дашборды и алерты.

-- Качество правил по «созревшим» дням: жалоба приходит до 14 дней, поэтому
-- свежие срабатывания без жалобы ещё нельзя считать ложными.
-- Точность (precision): доля срабатываний, подтверждённых жалобой.
-- Полнота (recall): доля подтверждённых мошеннических операций, на которые сработало правило.
-- Первые 30 дней факта не считаем: у признаков ещё нет полной истории («прогрев»),
-- любое устройство «новое», и правила там шумят (1 мая — 176 ночных P2P).
CREATE OR REPLACE VIEW v_fraud_rule_quality AS
WITH mature AS (
    SELECT f.first_day, l.last_day
    FROM (SELECT MIN(trx_date) + 30 AS first_day FROM fct_transactions) f,
         (SELECT MAX(reported_at) - 14 AS last_day FROM fraud_label) l
), alerts AS (
    SELECT a.rule_code, a.trx_id, CASE WHEN l.trx_id IS NOT NULL THEN 1 ELSE 0 END AS confirmed
    FROM fraud_alert a
    LEFT JOIN fraud_label l ON l.trx_id = a.trx_id
    WHERE a.alert_date BETWEEN (SELECT first_day FROM mature) AND (SELECT last_day FROM mature)
), labels AS (
    SELECT l.trx_id
    FROM fraud_label l
    JOIN fct_transactions f ON f.trx_id = l.trx_id
    WHERE f.trx_date BETWEEN (SELECT first_day FROM mature) AND (SELECT last_day FROM mature)
), with_total AS (
    SELECT rule_code, trx_id, confirmed FROM alerts
    UNION ALL
    -- «хоть одно правило»: операция с двумя срабатываниями считается один раз
    SELECT 'ANY_RULE', trx_id, MAX(confirmed) FROM alerts GROUP BY trx_id
)
SELECT rule_code,
       COUNT(*)                                         AS alerts,
       SUM(confirmed)                                   AS confirmed,
       ROUND(SUM(confirmed) / COUNT(*), 3)              AS precision,
       ROUND(SUM(confirmed) / (SELECT COUNT(*) FROM labels), 3) AS recall
FROM with_total
GROUP BY rule_code;
/

-- Полнота по видам мошенничества: какую долю каждого вида поймало хоть одно правило.
-- Считаем по операциям и по «карта-день» (банку достаточно поймать карту, а не все её операции).
CREATE OR REPLACE VIEW v_fraud_recall_by_type AS
WITH mature AS (
    SELECT f.first_day, l.last_day
    FROM (SELECT MIN(trx_date) + 30 AS first_day FROM fct_transactions) f,
         (SELECT MAX(reported_at) - 14 AS last_day FROM fraud_label) l
), labeled AS (
    SELECT l.fraud_type, f.trx_id, f.card_id, f.trx_date,
           CASE WHEN EXISTS (SELECT 1 FROM fraud_alert a WHERE a.trx_id = f.trx_id) THEN 1 ELSE 0 END AS trx_caught,
           CASE WHEN EXISTS (SELECT 1 FROM fraud_alert a
                             WHERE a.card_id = f.card_id AND a.alert_date = f.trx_date) THEN 1 ELSE 0 END AS card_day_caught
    FROM fraud_label l
    JOIN fct_transactions f ON f.trx_id = l.trx_id
    WHERE f.trx_date BETWEEN (SELECT first_day FROM mature) AND (SELECT last_day FROM mature)
)
SELECT fraud_type,
       COUNT(*)                                             AS fraud_trx,
       ROUND(AVG(trx_caught), 3)                            AS trx_recall,
       COUNT(DISTINCT card_id || '|' || trx_date)           AS fraud_card_days,
       ROUND(COUNT(DISTINCT CASE WHEN card_day_caught = 1 THEN card_id || '|' || trx_date END)
             / COUNT(DISTINCT card_id || '|' || trx_date), 3) AS card_day_recall
FROM labeled
GROUP BY fraud_type;
/

-- Просрочка по корзинам на конец каждого месяца (и на последний загруженный день).
-- Переплата наперёд — не «отрицательная просрочка», поэтому GREATEST(..., 0).
CREATE OR REPLACE VIEW v_dpd_buckets AS
SELECT snapshot_date, bucket, COUNT(*) AS loans, SUM(GREATEST(due_total - paid_total, 0)) AS overdue_amount,
       ROUND(RATIO_TO_REPORT(COUNT(*)) OVER (PARTITION BY snapshot_date), 4) AS loan_share
FROM mart_loan_dpd
WHERE snapshot_date = LAST_DAY(snapshot_date)
   OR snapshot_date = (SELECT MAX(snapshot_date) FROM mart_loan_dpd)
GROUP BY snapshot_date, bucket;
/

-- Roll rate: куда кредиты из корзины на конец месяца перешли к концу следующего.
CREATE OR REPLACE VIEW v_dpd_roll_rate AS
SELECT a.snapshot_date AS from_month_end, a.bucket AS from_bucket, NVL(b.bucket, 'closed') AS to_bucket,
       COUNT(*) AS loans,
       ROUND(RATIO_TO_REPORT(COUNT(*)) OVER (PARTITION BY a.snapshot_date, a.bucket), 4) AS loan_share
FROM mart_loan_dpd a
LEFT JOIN mart_loan_dpd b
       ON b.loan_id = a.loan_id AND b.snapshot_date = LAST_DAY(ADD_MONTHS(a.snapshot_date, 1))
WHERE a.snapshot_date = LAST_DAY(a.snapshot_date)
  AND LAST_DAY(ADD_MONTHS(a.snapshot_date, 1)) <= (SELECT MAX(snapshot_date) FROM mart_loan_dpd)
GROUP BY a.snapshot_date, a.bucket, NVL(b.bucket, 'closed');
/
