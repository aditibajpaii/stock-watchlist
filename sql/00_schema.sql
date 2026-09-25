-- =====================================================================
-- 00_schema.sql
-- Real-Time Stock Market Watchlist & Alert System
-- BCSE302P Database Systems Lab
--
-- Base schema: 7 tables, constraints, referential actions.
-- No functions, triggers or secondary indexes here (later phases).
--
-- Run:  psql -d stock_watchlist -v ON_ERROR_STOP=1 -f sql/00_schema.sql
-- Re-runnable: drops the tables first (DEVELOPMENT ONLY - destroys data).
-- =====================================================================

BEGIN;

DROP TABLE IF EXISTS alert_events    CASCADE;
DROP TABLE IF EXISTS alert_rules     CASCADE;
DROP TABLE IF EXISTS price_ticks     CASCADE;
DROP TABLE IF EXISTS watchlist_items CASCADE;
DROP TABLE IF EXISTS watchlists      CASCADE;
DROP TABLE IF EXISTS instruments     CASCADE;
DROP TABLE IF EXISTS users           CASCADE;

-- ---------------------------------------------------------------------
-- 1. users
-- ---------------------------------------------------------------------
CREATE TABLE users (
    user_id     BIGINT GENERATED ALWAYS AS IDENTITY,
    username    TEXT        NOT NULL,
    email       TEXT        NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT pk_users PRIMARY KEY (user_id),
    CONSTRAINT uq_users_username UNIQUE (username),
    CONSTRAINT uq_users_email UNIQUE (email),
    CONSTRAINT ck_users_username_format
        CHECK (username ~ '^[a-z0-9_]{3,30}$'),
    CONSTRAINT ck_users_email_format
        CHECK (email = lower(email) AND email LIKE '%_@_%')
);

-- ---------------------------------------------------------------------
-- 2. instruments
-- ---------------------------------------------------------------------
CREATE TABLE instruments (
    instrument_id   BIGINT GENERATED ALWAYS AS IDENTITY,
    exchange        TEXT    NOT NULL,
    symbol          TEXT    NOT NULL,
    name            TEXT    NOT NULL,
    quote_currency  TEXT    NOT NULL,
    is_active       BOOLEAN NOT NULL DEFAULT true,

    CONSTRAINT pk_instruments PRIMARY KEY (instrument_id),
    CONSTRAINT uq_instruments_exchange_symbol UNIQUE (exchange, symbol),
    CONSTRAINT ck_instruments_exchange
        CHECK (exchange IN ('NSE', 'BSE', 'BINANCE')),
    CONSTRAINT ck_instruments_symbol_format
        CHECK (symbol ~ '^[A-Z0-9&._-]{1,20}$'),
    CONSTRAINT ck_instruments_name_not_blank
        CHECK (btrim(name) <> ''),
    CONSTRAINT ck_instruments_quote_currency
        CHECK (quote_currency ~ '^[A-Z]{3,5}$')
);

-- ---------------------------------------------------------------------
-- 3. watchlists
-- ---------------------------------------------------------------------
CREATE TABLE watchlists (
    watchlist_id  BIGINT GENERATED ALWAYS AS IDENTITY,
    user_id       BIGINT      NOT NULL,
    name          TEXT        NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT pk_watchlists PRIMARY KEY (watchlist_id),
    CONSTRAINT fk_watchlists_user FOREIGN KEY (user_id)
        REFERENCES users (user_id) ON DELETE CASCADE,
    CONSTRAINT uq_watchlists_user_name UNIQUE (user_id, name),
    CONSTRAINT ck_watchlists_name
        CHECK (btrim(name) <> '' AND char_length(name) <= 50)
);

-- ---------------------------------------------------------------------
-- 4. watchlist_items  (resolves watchlists M:N instruments)
-- ---------------------------------------------------------------------
CREATE TABLE watchlist_items (
    watchlist_id   BIGINT      NOT NULL,
    instrument_id  BIGINT      NOT NULL,
    added_at       TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT pk_watchlist_items PRIMARY KEY (watchlist_id, instrument_id),
    CONSTRAINT fk_watchlist_items_watchlist FOREIGN KEY (watchlist_id)
        REFERENCES watchlists (watchlist_id) ON DELETE CASCADE,
    CONSTRAINT fk_watchlist_items_instrument FOREIGN KEY (instrument_id)
        REFERENCES instruments (instrument_id) ON DELETE RESTRICT
);

-- ---------------------------------------------------------------------
-- 5. price_ticks
-- ---------------------------------------------------------------------
CREATE TABLE price_ticks (
    tick_id          BIGINT GENERATED ALWAYS AS IDENTITY,
    instrument_id    BIGINT         NOT NULL,
    observed_at      TIMESTAMPTZ    NOT NULL,
    price            NUMERIC(18,8)  NOT NULL,
    volume           NUMERIC(24,8)  NULL,
    source           TEXT           NOT NULL,
    source_event_id  TEXT           NOT NULL,
    ingested_at      TIMESTAMPTZ    NOT NULL DEFAULT now(),

    CONSTRAINT pk_price_ticks PRIMARY KEY (tick_id),
    CONSTRAINT fk_price_ticks_instrument FOREIGN KEY (instrument_id)
        REFERENCES instruments (instrument_id) ON DELETE RESTRICT,
    CONSTRAINT uq_price_ticks_source_event
        UNIQUE (source, instrument_id, source_event_id),
    CONSTRAINT ck_price_ticks_price_pos
        CHECK (price > 0),
    CONSTRAINT ck_price_ticks_volume_nonneg
        CHECK (volume IS NULL OR volume >= 0),
    CONSTRAINT ck_price_ticks_source
        CHECK (source IN ('REPLAY', 'BINANCE', 'MANUAL')),
    CONSTRAINT ck_price_ticks_source_event_not_blank
        CHECK (btrim(source_event_id) <> '')
);

-- ---------------------------------------------------------------------
-- 6. alert_rules
-- ---------------------------------------------------------------------
CREATE TABLE alert_rules (
    rule_id           BIGINT GENERATED ALWAYS AS IDENTITY,
    user_id           BIGINT        NOT NULL,
    instrument_id     BIGINT        NOT NULL,
    direction         TEXT          NOT NULL,
    threshold         NUMERIC(18,8) NOT NULL,
    cooldown_seconds  INTEGER       NOT NULL DEFAULT 300,
    is_active         BOOLEAN       NOT NULL DEFAULT true,
    created_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),

    CONSTRAINT pk_alert_rules PRIMARY KEY (rule_id),
    CONSTRAINT fk_alert_rules_user FOREIGN KEY (user_id)
        REFERENCES users (user_id) ON DELETE CASCADE,
    CONSTRAINT fk_alert_rules_instrument FOREIGN KEY (instrument_id)
        REFERENCES instruments (instrument_id) ON DELETE RESTRICT,
    CONSTRAINT uq_alert_rules_definition
        UNIQUE (user_id, instrument_id, direction, threshold),
    CONSTRAINT ck_alert_rules_direction
        CHECK (direction IN ('ABOVE', 'BELOW')),
    CONSTRAINT ck_alert_rules_threshold_pos
        CHECK (threshold > 0),
    CONSTRAINT ck_alert_rules_cooldown_nonneg
        CHECK (cooldown_seconds >= 0)
);

-- ---------------------------------------------------------------------
-- 7. alert_events
-- ---------------------------------------------------------------------
CREATE TABLE alert_events (
    event_id  BIGINT GENERATED ALWAYS AS IDENTITY,
    rule_id   BIGINT      NOT NULL,
    tick_id   BIGINT      NOT NULL,
    fired_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT pk_alert_events PRIMARY KEY (event_id),
    CONSTRAINT fk_alert_events_rule FOREIGN KEY (rule_id)
        REFERENCES alert_rules (rule_id) ON DELETE CASCADE,
    CONSTRAINT fk_alert_events_tick FOREIGN KEY (tick_id)
        REFERENCES price_ticks (tick_id) ON DELETE RESTRICT,
    CONSTRAINT uq_alert_events_rule_tick UNIQUE (rule_id, tick_id)
);

COMMIT;
