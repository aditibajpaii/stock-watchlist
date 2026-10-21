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
