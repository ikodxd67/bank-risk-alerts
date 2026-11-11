-- Клиент «на дату» по журналу источника: каждая строка журнала действует с changed_at
-- до следующего изменения. Несколько изменений за день дают пустые интервалы
-- [d, d) — кроме последнего, поэтому «на дату» выбирается последнее изменение дня.
-- Читает pkg_dds.load_dims: WHERE p_date >= state_from AND p_date < state_to.

CREATE OR REPLACE VIEW v_client_asof AS
SELECT client_id, full_name, birth_date, city, segment,
       changed_at AS state_from,
       LEAD(changed_at, 1, DATE '9999-12-31')
           OVER (PARTITION BY client_id ORDER BY changed_at, hist_id) AS state_to
FROM src.client_history;
/

-- Операции источника в форме факта. Одно место на две загрузки:
-- ежедневную (load_transactions) и пересборку месяца (reload_month).
-- client_sk — версия клиента, действовавшая в день операции (point-in-time).
-- LEFT JOIN намеренно: неизвестная карта даст NULL и упадёт на NOT NULL факта.

CREATE OR REPLACE VIEW v_trx_src AS
SELECT t.trx_id,
       t.trx_ts,
       TRUNC(t.trx_ts) AS trx_date,
       t.card_id,
       c.client_id,
       d.client_sk,
       t.merchant_id,
       t.amount,
       t.channel,
       t.country,
       t.device_id,
       t.status
FROM src.transactions t
LEFT JOIN dim_card c
       ON c.card_id = t.card_id
LEFT JOIN dim_client d
       ON d.client_id = c.client_id
      AND t.trx_ts >= d.valid_from
      AND t.trx_ts <  d.valid_to;
/
