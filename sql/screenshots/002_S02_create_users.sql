\echo '========================================================================'
\echo ' S02 | CREATE TABLE users (statement copied from sql/00_schema.sql)'
\echo '========================================================================'
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
