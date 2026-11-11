-- Замеры шага 5: одна и та же загрузка операций четырьмя способами в черновую таблицу.
-- Не часть хранилища — накатывает и запускает scripts/perf.py.

CREATE TABLE IF NOT EXISTS perf_trx AS SELECT * FROM fct_transactions WHERE 1 = 0;
/

CREATE OR REPLACE PACKAGE pkg_perf AS
    -- 1. Построчно: курсорный цикл и INSERT на каждую строку (row-by-row, «slow-by-slow»).
    PROCEDURE row_by_row(p_from IN DATE, p_to IN DATE);
    -- 2. Пачками: BULK COLLECT ... LIMIT в коллекцию, FORALL INSERT пачки.
    PROCEDURE bulk_forall(p_from IN DATE, p_to IN DATE, p_limit IN PLS_INTEGER DEFAULT 1000);
    -- 3. Один SQL: INSERT ... SELECT.
    PROCEDURE one_sql(p_from IN DATE, p_to IN DATE);
    -- 4. Один SQL с прямой записью (direct-path): /*+ APPEND */ пишет блоки мимо буферного кэша.
    PROCEDURE one_sql_append(p_from IN DATE, p_to IN DATE);
END pkg_perf;
/

CREATE OR REPLACE PACKAGE BODY pkg_perf AS

    PROCEDURE row_by_row(p_from IN DATE, p_to IN DATE) IS
    BEGIN
        FOR r IN (SELECT * FROM v_trx_src WHERE trx_ts >= p_from AND trx_ts < p_to) LOOP
            INSERT INTO perf_trx (trx_id, trx_ts, trx_date, card_id, client_id, client_sk, merchant_id,
                                  amount, channel, country, device_id, status, loaded_at)
            VALUES (r.trx_id, r.trx_ts, r.trx_date, r.card_id, r.client_id, r.client_sk, r.merchant_id,
                    r.amount, r.channel, r.country, r.device_id, r.status, SYSTIMESTAMP);
        END LOOP;
        COMMIT;
    END row_by_row;

    PROCEDURE bulk_forall(p_from IN DATE, p_to IN DATE, p_limit IN PLS_INTEGER DEFAULT 1000) IS
        CURSOR c IS SELECT * FROM v_trx_src WHERE trx_ts >= p_from AND trx_ts < p_to;
        TYPE t_rows IS TABLE OF c%ROWTYPE;
        l_rows t_rows;
    BEGIN
        OPEN c;
        LOOP
            FETCH c BULK COLLECT INTO l_rows LIMIT p_limit;   -- LIMIT: память PGA не растёт с объёмом
            EXIT WHEN l_rows.COUNT = 0;
            FORALL i IN 1 .. l_rows.COUNT
                INSERT INTO perf_trx (trx_id, trx_ts, trx_date, card_id, client_id, client_sk, merchant_id,
                                      amount, channel, country, device_id, status, loaded_at)
                VALUES (l_rows(i).trx_id, l_rows(i).trx_ts, l_rows(i).trx_date, l_rows(i).card_id,
                        l_rows(i).client_id, l_rows(i).client_sk, l_rows(i).merchant_id, l_rows(i).amount,
                        l_rows(i).channel, l_rows(i).country, l_rows(i).device_id, l_rows(i).status,
                        SYSTIMESTAMP);
        END LOOP;
        CLOSE c;
        COMMIT;
    END bulk_forall;

    PROCEDURE one_sql(p_from IN DATE, p_to IN DATE) IS
    BEGIN
        INSERT INTO perf_trx (trx_id, trx_ts, trx_date, card_id, client_id, client_sk, merchant_id,
                              amount, channel, country, device_id, status, loaded_at)
        SELECT trx_id, trx_ts, trx_date, card_id, client_id, client_sk, merchant_id,
               amount, channel, country, device_id, status, SYSTIMESTAMP
        FROM v_trx_src WHERE trx_ts >= p_from AND trx_ts < p_to;
        COMMIT;
    END one_sql;

    PROCEDURE one_sql_append(p_from IN DATE, p_to IN DATE) IS
    BEGIN
        INSERT /*+ APPEND */ INTO perf_trx (trx_id, trx_ts, trx_date, card_id, client_id, client_sk, merchant_id,
                                            amount, channel, country, device_id, status, loaded_at)
        SELECT trx_id, trx_ts, trx_date, card_id, client_id, client_sk, merchant_id,
               amount, channel, country, device_id, status, SYSTIMESTAMP
        FROM v_trx_src WHERE trx_ts >= p_from AND trx_ts < p_to;
        COMMIT;   -- после APPEND таблицу нельзя читать в той же транзакции (ORA-12838)
    END one_sql_append;

END pkg_perf;
/
