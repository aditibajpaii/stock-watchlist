\echo '========================================================================'
\echo ' M02 | DML UPDATE: rename the watchlist; change a rule''s cooldown, then'
\echo '       set it back (a rule''s definition is never edited, only is_active/cooldown)'
\echo '========================================================================'
UPDATE watchlists SET name = 'Review 2 Demo (renamed)'
WHERE name = 'Review 2 Demo'
RETURNING watchlist_id, name;

UPDATE alert_rules SET cooldown_seconds = 600 WHERE rule_id = 3
RETURNING rule_id, direction, threshold::numeric(12,2), cooldown_seconds;

UPDATE alert_rules SET cooldown_seconds = 60 WHERE rule_id = 3
RETURNING rule_id, direction, threshold::numeric(12,2), cooldown_seconds;
