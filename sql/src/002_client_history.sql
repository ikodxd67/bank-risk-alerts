-- Журнал изменений клиентов (аудит). clients хранит только текущее состояние, а
-- хранилищу нужно состояние «на дату»: иначе загрузка прошлого дня видит сегодняшнего
-- клиента и история версий теряется. Пишет триггер — любая запись в clients попадает
-- сюда, кто бы её ни сделал. Полная копия строки после изменения, а не только поля.

CREATE TABLE client_history (
    hist_id    NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,   -- порядок изменений внутри дня
    client_id  NUMBER(10)    NOT NULL,
    full_name  VARCHAR2(100) NOT NULL,
    birth_date DATE          NOT NULL,
    city       VARCHAR2(50)  NOT NULL,
    segment    VARCHAR2(10)  NOT NULL,
    changed_at DATE          NOT NULL                               -- updated_at строки после изменения
);
/

CREATE INDEX ix_client_history ON client_history (client_id, changed_at);
/

CREATE OR REPLACE TRIGGER trg_clients_history
AFTER INSERT OR UPDATE ON clients
FOR EACH ROW
BEGIN
    INSERT INTO client_history (client_id, full_name, birth_date, city, segment, changed_at)
    VALUES (:NEW.client_id, :NEW.full_name, :NEW.birth_date, :NEW.city, :NEW.segment, :NEW.updated_at);
END;
/

GRANT SELECT ON client_history TO dwh;
/
