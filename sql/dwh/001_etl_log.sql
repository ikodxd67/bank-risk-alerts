-- Журнал загрузок: одна строка на шаг (load_dims, load_transactions, ...) за дату.
-- По нему потом строятся алерты «загрузка не прошла» и «строк меньше обычного».

CREATE TABLE etl_log (
    log_id      NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    step        VARCHAR2(50)   NOT NULL,
    load_date   DATE,
    status      VARCHAR2(10)   NOT NULL CHECK (status IN ('RUNNING', 'OK', 'ERROR')),
    row_cnt     NUMBER,
    started_at  TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
    finished_at TIMESTAMP,
    message     VARCHAR2(4000)
);
/
