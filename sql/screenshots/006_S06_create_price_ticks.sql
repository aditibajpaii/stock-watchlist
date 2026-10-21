\echo '========================================================================'
\echo ' S06 | CREATE TABLE price_ticks (statement copied from sql/00_schema.sql)'
\echo '========================================================================'
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
