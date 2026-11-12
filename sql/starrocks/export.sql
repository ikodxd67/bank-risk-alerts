-- Выгрузка дней ['{{ d1 }}', '{{ d2 }}'] из Oracle в StarRocks. Метки d1/d2 подставляются до отправки:
-- задача export_starrocks в DAG (один день, d1 = d2 = ds) и scripts/starrocks.sh export (диапазон).
-- Литералы, а не переменные сессии: DELETE из Aggregate/Duplicate-таблиц переменные не принимает.
-- Повторный запуск за те же дни даёт то же самое: день сначала удаляется.
-- shortcut: DELETE и INSERT — две команды, между ними день на мгновение пуст. Транзакции
-- с DELETE в StarRocks есть только в режиме shared-data (v4.0+); там обернуть в BEGIN/COMMIT.
-- Даты из каталога приходят строками 'YYYY-MM-DD HH:MI:SS' — приводим CAST-ом.

USE bank;

DELETE FROM turnover_daily WHERE report_date >= '{{ d1 }}' AND report_date <= '{{ d2 }}';
INSERT INTO turnover_daily
SELECT CAST(REPORT_DATE AS DATE), CHANNEL, IS_FOREIGN, TRX_CNT, DECLINED_CNT, APPROVED_AMOUNT, CARD_CNT
FROM oracle_dwh.DWH.MART_DAILY_TURNOVER
WHERE REPORT_DATE >= '{{ d1 }}' AND REPORT_DATE <= '{{ d2 }}';

-- В Aggregate-таблице повторная вставка сложила бы суммы второй раз — удаление обязательно.
DELETE FROM trx_hourly WHERE trx_date >= '{{ d1 }}' AND trx_date <= '{{ d2 }}';
INSERT INTO trx_hourly
SELECT CAST(TRX_DATE AS DATE), HOUR(CAST(TRX_TS AS DATETIME)), CHANNEL,
       IF(COUNTRY = 'KZ', 'N', 'Y'),
       1, IF(STATUS = 'DECLINED', 1, 0), IF(STATUS = 'APPROVED', AMOUNT, 0), AMOUNT,
       TO_BITMAP(CAST(CARD_ID AS BIGINT))
FROM oracle_dwh.DWH.FCT_TRANSACTIONS
WHERE TRX_DATE >= '{{ d1 }}' AND TRX_DATE <= '{{ d2 }}';

DELETE FROM fraud_alert WHERE alert_date >= '{{ d1 }}' AND alert_date <= '{{ d2 }}';
INSERT INTO fraud_alert
SELECT CAST(ALERT_DATE AS DATE), TRX_ID, RULE_CODE, CARD_ID, CLIENT_ID, CAST(TRX_TS AS DATETIME),
       AMOUNT, VALUE, THRESHOLD
FROM oracle_dwh.DWH.FRAUD_ALERT
WHERE ALERT_DATE >= '{{ d1 }}' AND ALERT_DATE <= '{{ d2 }}';

DELETE FROM loan_dpd WHERE snapshot_date >= '{{ d1 }}' AND snapshot_date <= '{{ d2 }}';
INSERT INTO loan_dpd
SELECT CAST(SNAPSHOT_DATE AS DATE), LOAN_ID, CLIENT_ID, PRINCIPAL, DUE_TOTAL, PAID_TOTAL, DPD, BUCKET
FROM oracle_dwh.DWH.MART_LOAN_DPD
WHERE SNAPSHOT_DATE >= '{{ d1 }}' AND SNAPSHOT_DATE <= '{{ d2 }}';

-- Жалобы и журнал не удаляем: строки там только добавляются и правятся, upsert по ключу хватает.
-- Жалобы — целиком: приходят за любые прошлые дни, таблица маленькая.
INSERT INTO fraud_label
SELECT TRX_ID, CAST(REPORTED_AT AS DATE), FRAUD_TYPE
FROM oracle_dwh.DWH.FRAUD_LABEL;

INSERT INTO etl_log
SELECT LOG_ID, STEP, CAST(LOAD_DATE AS DATE), STATUS, ROW_CNT,
       CAST(STARTED_AT AS DATETIME), CAST(FINISHED_AT AS DATETIME), MESSAGE
FROM oracle_dwh.DWH.ETL_LOG
WHERE LOAD_DATE >= '{{ d1 }}' AND LOAD_DATE <= '{{ d2 }}';
