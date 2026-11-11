-- Витрины: обороты, антифрод, просрочка. Каждая пересобирается за день (DELETE + INSERT).

CREATE TABLE mart_daily_turnover (
    report_date     DATE         NOT NULL,
    channel         VARCHAR2(6)  NOT NULL,
    is_foreign      CHAR(1)      NOT NULL,
    trx_cnt         NUMBER       NOT NULL,
    declined_cnt    NUMBER       NOT NULL,
    approved_amount NUMBER(16,2) NOT NULL,
    card_cnt        NUMBER       NOT NULL,
    CONSTRAINT pk_mart_daily_turnover PRIMARY KEY (report_date, channel, is_foreign)
);
/

-- Правила антифрода. Логика правила — в pkg_marts, порог — здесь:
-- менять порог можно без выкатки кода, следующая пересборка дня его подхватит.
CREATE TABLE fraud_rule (
    rule_code   VARCHAR2(30)  PRIMARY KEY,
    description VARCHAR2(400) NOT NULL,
    threshold   NUMBER        NOT NULL,
    min_history NUMBER        DEFAULT 0 NOT NULL,
    is_active   CHAR(1)       DEFAULT 'Y' NOT NULL CHECK (is_active IN ('Y', 'N'))
);
/

INSERT INTO fraud_rule (rule_code, description, threshold, min_history) VALUES
    ('VELOCITY_1H', 'онлайн-операций по карте за последний час (с текущей) не меньше threshold', 5, 0);
/
INSERT INTO fraud_rule (rule_code, description, threshold, min_history) VALUES
    ('AMOUNT_30D', 'сумма не меньше threshold × средняя одобренная сумма карты за 30 дней; нужно min_history операций истории', 8, 3);
/
INSERT INTO fraud_rule (rule_code, description, threshold, min_history) VALUES
    ('GEO_SWITCH', 'покупка POS за границей, предыдущая операция карты — в KZ не раньше чем threshold минут назад', 180, 0);
/
INSERT INTO fraud_rule (rule_code, description, threshold, min_history) VALUES
    ('NIGHT_P2P_NEW_DEVICE', 'перевод P2P с 00 до 06 с устройства, которого у карты не было 30 дней (до часа назад), сумма не меньше threshold × средней за 30 дней', 3, 0);
/
COMMIT;
/

-- Признаки операции для правил: окна по карте на 1 час, 24 часа, 30 дней.
CREATE TABLE mart_trx_features (
    trx_id             NUMBER(14)   NOT NULL,
    trx_date           DATE         NOT NULL,
    trx_ts             TIMESTAMP    NOT NULL,
    card_id            NUMBER(12)   NOT NULL,
    client_id          NUMBER(10)   NOT NULL,
    amount             NUMBER(14,2) NOT NULL,
    channel            VARCHAR2(6)  NOT NULL,
    country            CHAR(2)      NOT NULL,
    online_cnt_1h      NUMBER       NOT NULL,
    trx_cnt_24h        NUMBER       NOT NULL,
    approved_cnt_30d   NUMBER       NOT NULL,
    avg_amount_30d     NUMBER(14,2),
    device_seen_30d    NUMBER       NOT NULL,
    prev_country       CHAR(2),
    minutes_since_prev NUMBER
)
PARTITION BY RANGE (trx_date) INTERVAL (NUMTOYMINTERVAL(1, 'MONTH'))
(PARTITION p_start VALUES LESS THAN (DATE '2026-01-01'));
/

CREATE TABLE fraud_alert (
    alert_date DATE         NOT NULL,
    trx_id     NUMBER(14)   NOT NULL,
    rule_code  VARCHAR2(30) NOT NULL,
    card_id    NUMBER(12)   NOT NULL,
    client_id  NUMBER(10)   NOT NULL,
    trx_ts     TIMESTAMP    NOT NULL,
    amount     NUMBER(14,2) NOT NULL,
    value      NUMBER       NOT NULL,      -- что намерило правило: число операций, кратность суммы, минуты
    threshold  NUMBER       NOT NULL,      -- порог на момент срабатывания
    CONSTRAINT pk_fraud_alert PRIMARY KEY (trx_id, rule_code)
);
/

CREATE INDEX ix_fraud_alert_date ON fraud_alert (alert_date);
/

-- Подтверждённое мошенничество (жалобы). Приходит с опозданием до 14 дней,
-- поэтому качество правил честно считать только по «созревшим» дням.
CREATE TABLE fraud_label (
    trx_id      NUMBER(14)   PRIMARY KEY,
    reported_at DATE         NOT NULL,
    fraud_type  VARCHAR2(20) NOT NULL
);
/

-- Просрочка: снимок на каждый день по каждому действующему кредиту.
CREATE TABLE mart_loan_dpd (
    snapshot_date  DATE         NOT NULL,
    loan_id        NUMBER(10)   NOT NULL,
    client_id      NUMBER(10)   NOT NULL,
    principal      NUMBER(14,2) NOT NULL,
    due_cnt        NUMBER       NOT NULL,
    due_total      NUMBER(16,2) NOT NULL,
    paid_total     NUMBER(16,2) NOT NULL,
    dpd            NUMBER       NOT NULL,
    bucket         VARCHAR2(5)  NOT NULL
)
PARTITION BY RANGE (snapshot_date) INTERVAL (NUMTOYMINTERVAL(1, 'MONTH'))
(PARTITION p_start VALUES LESS THAN (DATE '2026-01-01'));
/
