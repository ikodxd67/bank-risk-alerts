-- Среднее «за 30 дней» теперь считается только по покупкам (без снятий в банкомате):
-- снятие наличных обычно крупнее покупки, и в общем среднем оно давало 77 % ложных
-- срабатываний AMOUNT_30D, а настоящее мошенничество, наоборот, прятало.

ALTER TABLE mart_trx_features RENAME COLUMN approved_cnt_30d TO purchase_cnt_30d;
/
ALTER TABLE mart_trx_features RENAME COLUMN avg_amount_30d TO avg_purchase_30d;
/
UPDATE fraud_rule
SET description = 'покупка (не банкомат) не меньше threshold × средняя одобренная покупка карты за 30 дней; нужно min_history покупок истории'
WHERE rule_code = 'AMOUNT_30D';
/
UPDATE fraud_rule
SET description = 'перевод P2P с 00 до 06 с устройства, которого у карты не было 30 дней (до часа назад), сумма не меньше threshold × средней покупки за 30 дней'
WHERE rule_code = 'NIGHT_P2P_NEW_DEVICE';
/
