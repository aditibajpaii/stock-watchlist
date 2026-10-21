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
