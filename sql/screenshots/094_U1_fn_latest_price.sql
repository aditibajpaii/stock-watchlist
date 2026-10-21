\sf reporting.fn_latest_price
SELECT symbol, reporting.fn_latest_price(instrument_id) AS latest_price FROM instruments;
