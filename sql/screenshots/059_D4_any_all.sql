SELECT tick_id, price
FROM price_ticks
WHERE instrument_id = 1
  AND price > ALL (SELECT threshold FROM alert_rules WHERE instrument_id = 1);

SELECT tick_id, price
FROM price_ticks
WHERE instrument_id = 2
  AND price < ANY (SELECT threshold FROM alert_rules WHERE instrument_id = 2);
