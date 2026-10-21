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
