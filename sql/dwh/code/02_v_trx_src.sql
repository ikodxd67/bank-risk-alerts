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
