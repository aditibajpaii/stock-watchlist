\echo '========================================================================'
\echo ' S05 | CREATE TABLE watchlist_items (statement copied from sql/00_schema.sql)'
\echo '========================================================================'
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
