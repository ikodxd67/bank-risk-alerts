-- StarRocks: каталог на Oracle и таблицы под дашборды и алерты.
-- Накат: scripts/starrocks.sh init (подставляет пароль из .env). Повторный запуск безопасен.

-- Каталог (external catalog): StarRocks читает таблицы Oracle по JDBC как свои.
-- Без "oracle.temporal.to-datetime": с ним фильтр по дате уходит в Oracle как
-- timestamp '...', Oracle приводит колонку DATE к TIMESTAMP и читает все партиции
-- (PARTITION RANGE ALL). Без него уходит date '...' — читается одна партиция.
-- Цена: даты приходят строками, приводим их в SELECT (см. export.sql).
-- shortcut: подключение владельцем схемы dwh; в проде — отдельный пользователь только на чтение.
CREATE EXTERNAL CATALOG IF NOT EXISTS oracle_dwh PROPERTIES (
    "type" = "jdbc",
    "user" = "dwh",
    "password" = "${DWH_PASSWORD}",
    "jdbc_uri" = "jdbc:oracle:thin:@oracle:1521/FREEPDB1",
    "driver_url" = "https://repo1.maven.org/maven2/com/oracle/database/jdbc/ojdbc10/19.18.0.0/ojdbc10-19.18.0.0.jar",
    "driver_class" = "oracle.jdbc.driver.OracleDriver"
);

CREATE DATABASE IF NOT EXISTS bank;
USE bank;

-- replication_num = 1 везде: на стенде один BE, по умолчанию StarRocks хочет 3 копии.

-- Primary Key: одна строка на ключ, вставка с тем же ключом заменяет строку (upsert).
CREATE TABLE IF NOT EXISTS turnover_daily (
    report_date     DATE NOT NULL,
    channel         VARCHAR(6) NOT NULL,
    is_foreign      VARCHAR(1) NOT NULL,   -- CHAR в первичном ключе StarRocks не разрешён
    trx_cnt         BIGINT NOT NULL,
    declined_cnt    BIGINT NOT NULL,
    approved_amount DECIMAL(16, 2) NOT NULL,
    card_cnt        BIGINT NOT NULL
) PRIMARY KEY (report_date, channel, is_foreign)
DISTRIBUTED BY HASH (report_date) BUCKETS 1
PROPERTIES ("replication_num" = "1");

-- Aggregate: строки с одинаковым ключом StarRocks сам сворачивает при записи.
-- cards — битовая карта номеров карт (BITMAP_UNION): число разных карт за любой
-- период считается точно. card_cnt из turnover_daily складывать по дням нельзя —
-- одна карта попадёт в сумму много раз.
CREATE TABLE IF NOT EXISTS trx_hourly (
    trx_date        DATE NOT NULL,
    trx_hour        TINYINT NOT NULL,
    channel         VARCHAR(6) NOT NULL,
    is_foreign      VARCHAR(1) NOT NULL,   -- CHAR в первичном ключе StarRocks не разрешён
    trx_cnt         BIGINT SUM NOT NULL,
    declined_cnt    BIGINT SUM NOT NULL,
    approved_amount DECIMAL(18, 2) SUM NOT NULL,
    max_amount      DECIMAL(14, 2) MAX NOT NULL,
    cards           BITMAP BITMAP_UNION NOT NULL
) AGGREGATE KEY (trx_date, trx_hour, channel, is_foreign)
PARTITION BY date_trunc('month', trx_date)
DISTRIBUTED BY HASH (trx_date) BUCKETS 1
PROPERTIES ("replication_num" = "1");

CREATE TABLE IF NOT EXISTS fraud_alert (
    alert_date DATE NOT NULL,
    trx_id     BIGINT NOT NULL,
    rule_code  VARCHAR(30) NOT NULL,
    card_id    BIGINT NOT NULL,
    client_id  BIGINT NOT NULL,
    trx_ts     DATETIME NOT NULL,
    amount     DECIMAL(14, 2) NOT NULL,
    value      DECIMAL(18, 2),
    threshold  DECIMAL(18, 2) NOT NULL
) PRIMARY KEY (alert_date, trx_id, rule_code)
DISTRIBUTED BY HASH (alert_date) BUCKETS 1
PROPERTIES ("replication_num" = "1");

-- Жалобы приходят с опозданием и за любые прошлые дни — как раз случай для upsert.
CREATE TABLE IF NOT EXISTS fraud_label (
    trx_id      BIGINT NOT NULL,
    reported_at DATE NOT NULL,
    fraud_type  VARCHAR(20) NOT NULL
) PRIMARY KEY (trx_id)
DISTRIBUTED BY HASH (trx_id) BUCKETS 1
PROPERTIES ("replication_num" = "1");

-- Duplicate Key: подробные строки как есть, ключ — только порядок сортировки.
CREATE TABLE IF NOT EXISTS loan_dpd (
    snapshot_date DATE NOT NULL,
    loan_id       BIGINT NOT NULL,
    client_id     BIGINT NOT NULL,
    principal     DECIMAL(14, 2) NOT NULL,
    due_total     DECIMAL(16, 2) NOT NULL,
    paid_total    DECIMAL(16, 2) NOT NULL,
    dpd           INT NOT NULL,
    bucket        VARCHAR(5) NOT NULL
) DUPLICATE KEY (snapshot_date, loan_id)
PARTITION BY date_trunc('month', snapshot_date)
DISTRIBUTED BY HASH (loan_id) BUCKETS 1
PROPERTIES ("replication_num" = "1");

-- Журнал загрузок Oracle: по нему Grafana считает свежесть данных.
CREATE TABLE IF NOT EXISTS etl_log (
    log_id      BIGINT NOT NULL,
    step        VARCHAR(50) NOT NULL,
    load_date   DATE,
    status      VARCHAR(10) NOT NULL,
    row_cnt     BIGINT,
    started_at  DATETIME NOT NULL,
    finished_at DATETIME,
    message     VARCHAR(4000)
) PRIMARY KEY (log_id)
DISTRIBUTED BY HASH (log_id) BUCKETS 1
PROPERTIES ("replication_num" = "1");

-- Асинхронные материализованные представления: StarRocks сам пересчитывает их
-- после изменения базовой таблицы (REFRESH ASYNC), дашборд читает готовый итог.

-- Просрочка по корзинам на каждый день; обновляется по месячным партициям loan_dpd.
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_dpd_buckets
PARTITION BY date_trunc('month', snapshot_date)
DISTRIBUTED BY HASH (snapshot_date) BUCKETS 1
REFRESH ASYNC
PROPERTIES ("replication_num" = "1")
AS
SELECT snapshot_date, bucket,
       COUNT(*) AS loans,
       SUM(GREATEST(due_total - paid_total, 0)) AS overdue_amount
FROM loan_dpd
GROUP BY snapshot_date, bucket;

-- Срабатывания правил по дням и сколько из них подтверждено жалобой.
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_rule_daily
DISTRIBUTED BY HASH (alert_date) BUCKETS 1
REFRESH ASYNC
PROPERTIES ("replication_num" = "1")
AS
SELECT a.alert_date, a.rule_code,
       COUNT(*) AS alerts,
       COUNT(l.trx_id) AS confirmed
FROM fraud_alert a
LEFT JOIN fraud_label l ON l.trx_id = a.trx_id
GROUP BY a.alert_date, a.rule_code;
