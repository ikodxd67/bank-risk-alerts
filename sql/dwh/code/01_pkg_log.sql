-- Код (пакеты, представления) накатывается при каждом `bra migrate dwh`: CREATE OR REPLACE.

CREATE OR REPLACE PACKAGE pkg_log AS
    -- открывает строку журнала со статусом RUNNING, возвращает её номер
    FUNCTION start_step(p_step IN VARCHAR2, p_load_date IN DATE) RETURN NUMBER;
    PROCEDURE ok(p_log_id IN NUMBER, p_rows IN NUMBER);
    PROCEDURE fail(p_log_id IN NUMBER, p_message IN VARCHAR2);
END pkg_log;
/

CREATE OR REPLACE PACKAGE BODY pkg_log AS

    -- Все три — автономные транзакции: запись в журнал коммитится отдельно
    -- и не откатывается вместе с упавшей загрузкой.

    FUNCTION start_step(p_step IN VARCHAR2, p_load_date IN DATE) RETURN NUMBER IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        l_id etl_log.log_id%TYPE;
    BEGIN
        INSERT INTO etl_log (step, load_date, status)
        VALUES (p_step, p_load_date, 'RUNNING')
        RETURNING log_id INTO l_id;
        COMMIT;
        RETURN l_id;
    END start_step;

    PROCEDURE ok(p_log_id IN NUMBER, p_rows IN NUMBER) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        UPDATE etl_log
        SET status = 'OK', row_cnt = p_rows, finished_at = SYSTIMESTAMP
        WHERE log_id = p_log_id;
        COMMIT;
    END ok;

    PROCEDURE fail(p_log_id IN NUMBER, p_message IN VARCHAR2) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        UPDATE etl_log
        SET status = 'ERROR', finished_at = SYSTIMESTAMP, message = SUBSTR(p_message, 1, 4000)
        WHERE log_id = p_log_id;
        COMMIT;
    END fail;

END pkg_log;
/
