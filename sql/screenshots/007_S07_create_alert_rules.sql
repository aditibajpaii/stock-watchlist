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
