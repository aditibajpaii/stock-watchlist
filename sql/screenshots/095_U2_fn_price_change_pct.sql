\sf reporting.fn_price_change_pct
SELECT symbol, reporting.fn_price_change_pct(instrument_id) AS change_pct FROM instruments;
