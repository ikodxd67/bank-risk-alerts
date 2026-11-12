-- Сверка StarRocks с Oracle. StarRocks видит обе стороны (свои таблицы и каталог
-- oracle_dwh), поэтому сверка — один запрос на таблицу. Запуск: scripts/starrocks.sh check

USE bank;

SELECT 'операции по месяцам: trx_hourly (StarRocks) против fct_transactions (Oracle)' AS `сверка`;
SELECT o.m AS month, o.n AS ora_trx, s.n AS sr_trx, o.amt AS ora_approved, s.amt AS sr_approved,
       o.cards AS ora_cards, s.cards AS sr_cards,
       IF(o.n = s.n AND o.amt = s.amt AND o.cards = s.cards, 'OK', 'DIFF') AS result
FROM (SELECT SUBSTR(TRX_DATE, 1, 7) AS m, COUNT(*) AS n,
             SUM(IF(STATUS = 'APPROVED', AMOUNT, 0)) AS amt, COUNT(DISTINCT CARD_ID) AS cards
      FROM oracle_dwh.DWH.FCT_TRANSACTIONS WHERE TRX_DATE >= '2026-05-01' GROUP BY 1) o
LEFT JOIN (SELECT DATE_FORMAT(trx_date, '%Y-%m') AS m, SUM(trx_cnt) AS n, SUM(approved_amount) AS amt,
                  BITMAP_UNION_COUNT(cards) AS cards
           FROM trx_hourly GROUP BY 1) s ON s.m = o.m
ORDER BY 1;

SELECT 'остальные таблицы: строк и контрольная сумма' AS `сверка`;
SELECT t, ora_rows, sr_rows, ora_sum, sr_sum, IF(ora_rows = sr_rows AND ora_sum = sr_sum, 'OK', 'DIFF') AS result
FROM (
    SELECT 'turnover_daily' AS t,
           (SELECT COUNT(*) FROM oracle_dwh.DWH.MART_DAILY_TURNOVER) AS ora_rows,
           (SELECT COUNT(*) FROM turnover_daily) AS sr_rows,
           (SELECT SUM(APPROVED_AMOUNT) FROM oracle_dwh.DWH.MART_DAILY_TURNOVER) AS ora_sum,
           (SELECT SUM(approved_amount) FROM turnover_daily) AS sr_sum
    UNION ALL
    SELECT 'fraud_alert',
           (SELECT COUNT(*) FROM oracle_dwh.DWH.FRAUD_ALERT), (SELECT COUNT(*) FROM fraud_alert),
           (SELECT SUM(AMOUNT) FROM oracle_dwh.DWH.FRAUD_ALERT), (SELECT SUM(amount) FROM fraud_alert)
    UNION ALL
    SELECT 'fraud_label',
           (SELECT COUNT(*) FROM oracle_dwh.DWH.FRAUD_LABEL), (SELECT COUNT(*) FROM fraud_label),
           (SELECT SUM(TRX_ID) FROM oracle_dwh.DWH.FRAUD_LABEL), (SELECT SUM(trx_id) FROM fraud_label)
    UNION ALL
    SELECT 'loan_dpd',
           (SELECT COUNT(*) FROM oracle_dwh.DWH.MART_LOAN_DPD), (SELECT COUNT(*) FROM loan_dpd),
           (SELECT SUM(DPD) FROM oracle_dwh.DWH.MART_LOAN_DPD), (SELECT SUM(dpd) FROM loan_dpd)
) x;

SELECT 'материализованные представления против своих базовых таблиц' AS `сверка`;
SELECT 'mv_dpd_buckets' AS mv, (SELECT SUM(loans) FROM mv_dpd_buckets) AS mv_total,
       (SELECT COUNT(*) FROM loan_dpd) AS base_total
UNION ALL
SELECT 'mv_rule_daily', (SELECT SUM(alerts) FROM mv_rule_daily), (SELECT COUNT(*) FROM fraud_alert);
