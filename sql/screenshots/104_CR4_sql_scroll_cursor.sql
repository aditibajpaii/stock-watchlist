BEGIN;
DECLARE c_btc SCROLL CURSOR FOR
    SELECT tick_id, observed_at, price FROM price_ticks WHERE instrument_id = 6 ORDER BY observed_at;
FETCH FIRST FROM c_btc;
FETCH FORWARD 2 FROM c_btc;
FETCH LAST FROM c_btc;
FETCH ABSOLUTE 4 FROM c_btc;
CLOSE c_btc;
COMMIT;
