-- =====================================================================
-- 01_seed.sql
-- Small deterministic demo data. No price_ticks (those come from
-- ingestion in later phases).
--
-- Run:  psql -d stock_watchlist -v ON_ERROR_STOP=1 -f sql/01_seed.sql
-- Re-runnable: empties all tables and restarts identity counters
-- (DEVELOPMENT ONLY - destroys data).
--
-- Foreign keys are looked up by natural key (username, exchange+symbol,
-- user+watchlist name) instead of hard-coded ids. ORDER BY on each
-- INSERT ... SELECT makes the generated ids deterministic.
-- =====================================================================

BEGIN;

TRUNCATE alert_events, alert_rules, price_ticks, watchlist_items,
         watchlists, instruments, users
RESTART IDENTITY;

-- ---------------------------------------------------------------------
-- users
-- ---------------------------------------------------------------------
INSERT INTO users (username, email) VALUES
    ('arjun', 'arjun@example.com'),
    ('priya', 'priya@example.com'),
    ('kavya', 'kavya@example.com');

-- ---------------------------------------------------------------------
-- instruments: 5 NSE equities + 2 Binance crypto pairs
-- ---------------------------------------------------------------------
INSERT INTO instruments (exchange, symbol, name, quote_currency) VALUES
    ('NSE',     'RELIANCE', 'Reliance Industries Ltd',      'INR'),
    ('NSE',     'TCS',      'Tata Consultancy Services Ltd', 'INR'),
    ('NSE',     'INFY',     'Infosys Ltd',                  'INR'),
    ('NSE',     'HDFCBANK', 'HDFC Bank Ltd',                'INR'),
    ('NSE',     'M&M',      'Mahindra & Mahindra Ltd',      'INR'),
    ('BINANCE', 'BTCUSDT',  'Bitcoin / Tether',             'USDT'),
    ('BINANCE', 'ETHUSDT',  'Ether / Tether',               'USDT');

-- ---------------------------------------------------------------------
-- watchlists
-- ---------------------------------------------------------------------
INSERT INTO watchlists (user_id, name)
SELECT u.user_id, w.name
FROM (VALUES
        ('arjun', 'Long Term'),
        ('arjun', 'Crypto'),
        ('priya', 'Tech'),
        ('priya', 'Auto'),
        ('kavya', 'Main')
     ) AS w(username, name)
JOIN users u ON u.username = w.username
ORDER BY u.user_id, w.name;

-- ---------------------------------------------------------------------
-- watchlist_items
-- ---------------------------------------------------------------------
INSERT INTO watchlist_items (watchlist_id, instrument_id)
SELECT wl.watchlist_id, i.instrument_id
FROM (VALUES
        ('arjun', 'Long Term', 'NSE',     'RELIANCE'),
        ('arjun', 'Long Term', 'NSE',     'TCS'),
        ('arjun', 'Long Term', 'NSE',     'HDFCBANK'),
        ('arjun', 'Crypto',    'BINANCE', 'BTCUSDT'),
        ('arjun', 'Crypto',    'BINANCE', 'ETHUSDT'),
        ('priya', 'Tech',      'NSE',     'TCS'),
        ('priya', 'Tech',      'NSE',     'INFY'),
        ('priya', 'Auto',      'NSE',     'M&M'),
        ('kavya', 'Main',      'NSE',     'RELIANCE'),
        ('kavya', 'Main',      'NSE',     'INFY'),
        ('kavya', 'Main',      'BINANCE', 'BTCUSDT')
     ) AS x(username, list_name, exchange, symbol)
JOIN users u        ON u.username = x.username
JOIN watchlists wl  ON wl.user_id = u.user_id AND wl.name = x.list_name
JOIN instruments i  ON i.exchange = x.exchange AND i.symbol = x.symbol
ORDER BY wl.watchlist_id, i.instrument_id;

-- ---------------------------------------------------------------------
-- alert_rules  (thresholds are demo values, not market advice)
-- ---------------------------------------------------------------------
INSERT INTO alert_rules
    (user_id, instrument_id, direction, threshold, cooldown_seconds, is_active)
SELECT u.user_id, i.instrument_id, r.direction, r.threshold, r.cooldown, r.active
FROM (VALUES
        (1, 'arjun', 'NSE',     'RELIANCE', 'ABOVE',   3000.00, 300, true),
        (2, 'arjun', 'NSE',     'RELIANCE', 'BELOW',   2800.00, 300, true),
        (3, 'arjun', 'BINANCE', 'BTCUSDT',  'ABOVE', 100000.00,  60, true),
        (4, 'priya', 'NSE',     'TCS',      'BELOW',   3500.00,   0, true),
        (5, 'priya', 'NSE',     'INFY',     'ABOVE',   1600.00, 600, false),
        (6, 'kavya', 'BINANCE', 'ETHUSDT',  'BELOW',   3000.00, 120, true)
     ) AS r(ord, username, exchange, symbol, direction, threshold, cooldown, active)
JOIN users u       ON u.username = r.username
JOIN instruments i ON i.exchange = r.exchange AND i.symbol = r.symbol
ORDER BY r.ord;

COMMIT;
