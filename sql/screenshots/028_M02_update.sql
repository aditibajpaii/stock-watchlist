UPDATE watchlists SET name = 'My Favourites' WHERE name = 'Favourites' RETURNING *;

UPDATE alert_rules SET cooldown_seconds = 600 WHERE rule_id = 3 RETURNING rule_id, cooldown_seconds;

UPDATE alert_rules SET cooldown_seconds = 60 WHERE rule_id = 3 RETURNING rule_id, cooldown_seconds;
