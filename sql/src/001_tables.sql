-- Учётная система банка (источник). Данные синтетические, см. src/bra/generator.py.
-- Команды разделены строкой «/», файл исполняется и через sqlplus, и через `bra migrate src`.

CREATE TABLE clients (
    client_id     NUMBER(10)    PRIMARY KEY,
    full_name     VARCHAR2(100) NOT NULL,
    birth_date    DATE          NOT NULL,
    city          VARCHAR2(50)  NOT NULL,
    segment       VARCHAR2(10)  NOT NULL CHECK (segment IN ('MASS', 'PREMIUM')),
    registered_at DATE          NOT NULL,
    updated_at    DATE          NOT NULL
);
/

CREATE TABLE cards (
    card_id   NUMBER(12)   PRIMARY KEY,
    client_id NUMBER(10)   NOT NULL REFERENCES clients,
    card_type VARCHAR2(10) NOT NULL CHECK (card_type IN ('DEBIT', 'CREDIT')),
    opened_at DATE         NOT NULL
);
/

-- mcc — код категории продавца (merchant category code), 5411 = продукты и т. д.
CREATE TABLE merchants (
    merchant_id NUMBER(8)     PRIMARY KEY,
    name        VARCHAR2(100) NOT NULL,
    mcc         CHAR(4)       NOT NULL,
    country     CHAR(2)       NOT NULL
);
/

-- merchant_id пуст у снятия в банкомате и перевода (ATM, P2P);
-- device_id есть только у ONLINE и P2P.
CREATE TABLE transactions (
    trx_id      NUMBER(14)   PRIMARY KEY,
    card_id     NUMBER(12)   NOT NULL REFERENCES cards,
    merchant_id NUMBER(8)    REFERENCES merchants,
    trx_ts      TIMESTAMP    NOT NULL,
    amount      NUMBER(14,2) NOT NULL CHECK (amount > 0),
    channel     VARCHAR2(6)  NOT NULL CHECK (channel IN ('POS', 'ONLINE', 'ATM', 'P2P')),
    country     CHAR(2)      NOT NULL,
    device_id   VARCHAR2(20),
    status      VARCHAR2(8)  NOT NULL CHECK (status IN ('APPROVED', 'DECLINED'))
);
/

CREATE INDEX ix_transactions_ts ON transactions (trx_ts);
/

-- Подтверждённое мошенничество (жалоба клиента, chargeback). Приходит из другой
-- системы с задержкой 1–14 дней и не по всем случаям, поэтому без внешнего ключа.
CREATE TABLE fraud_reports (
    trx_id      NUMBER(14)   PRIMARY KEY,
    reported_at DATE         NOT NULL,
    fraud_type  VARCHAR2(20) NOT NULL
);
/

CREATE TABLE loans (
    loan_id         NUMBER(10)   PRIMARY KEY,
    client_id       NUMBER(10)   NOT NULL REFERENCES clients,
    issued_on       DATE         NOT NULL,
    principal       NUMBER(14,2) NOT NULL,
    term_months     NUMBER(3)    NOT NULL,
    monthly_payment NUMBER(14,2) NOT NULL
);
/

-- Платёж положен каждый месяц в день выдачи; график хранилище строит само.
CREATE TABLE loan_payments (
    payment_id NUMBER(14)   PRIMARY KEY,
    loan_id    NUMBER(10)   NOT NULL REFERENCES loans,
    paid_on    DATE         NOT NULL,
    amount     NUMBER(14,2) NOT NULL
);
/

CREATE INDEX ix_loan_payments_paid ON loan_payments (paid_on);
/

GRANT SELECT ON clients TO dwh;
/
GRANT SELECT ON cards TO dwh;
/
GRANT SELECT ON merchants TO dwh;
/
GRANT SELECT ON transactions TO dwh;
/
GRANT SELECT ON fraud_reports TO dwh;
/
GRANT SELECT ON loans TO dwh;
/
GRANT SELECT ON loan_payments TO dwh;
/
