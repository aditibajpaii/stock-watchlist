\echo '========================================================================'
\echo ' SEC3 | Role / privilege matrix (has_table_privilege)'
\echo '========================================================================'
SELECT rl AS role, tbl AS object,
       has_table_privilege(rl, tbl, 'SELECT') AS sel,
       has_table_privilege(rl, tbl, 'INSERT') AS ins,
       has_table_privilege(rl, tbl, 'UPDATE') AS upd,
       has_table_privilege(rl, tbl, 'DELETE') AS del
FROM unnest(ARRAY['sw_admin', 'sw_analyst', 'sw_enduser']) AS rl,
     unnest(ARRAY['users', 'alert_rules', 'price_ticks', 'instruments',
                  'reporting.v_instrument_price_summary', 'reporting.v_my_alerts']) AS tbl
ORDER BY rl, tbl;
