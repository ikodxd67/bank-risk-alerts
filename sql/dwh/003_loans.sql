-- Кредиты в детальном слое: договор, график платежей, фактические платежи.

CREATE TABLE dim_loan (
    loan_id         NUMBER(10)   PRIMARY KEY,
    client_id       NUMBER(10)   NOT NULL,
    issued_on       DATE         NOT NULL,
    principal       NUMBER(14,2) NOT NULL,
    term_months     NUMBER(3)    NOT NULL,
    monthly_payment NUMBER(14,2) NOT NULL
);
/

-- В источнике графика нет: платёж положен каждый месяц в день выдачи,
-- в коротком месяце — в последний день (31 января → 28 февраля).
CREATE TABLE loan_schedule (
    loan_id        NUMBER(10)   NOT NULL,
    installment_no NUMBER(3)    NOT NULL,
    due_date       DATE         NOT NULL,
    amount         NUMBER(14,2) NOT NULL,
    CONSTRAINT pk_loan_schedule PRIMARY KEY (loan_id, installment_no)
);
/

CREATE TABLE fct_loan_payment (
    payment_id NUMBER(14)   PRIMARY KEY,
    loan_id    NUMBER(10)   NOT NULL,
    paid_on    DATE         NOT NULL,
    amount     NUMBER(14,2) NOT NULL
);
/

CREATE INDEX ix_fct_loan_payment_paid ON fct_loan_payment (paid_on);
/
