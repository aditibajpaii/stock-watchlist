\echo '========================================================================'
\echo ' T1 | The 2 triggers (information_schema.triggers)'
\echo '========================================================================'
SELECT trigger_name, action_timing AS timing, event_manipulation AS event,
       event_object_table AS on_table, action_orientation AS for_each,
       action_statement
FROM information_schema.triggers
WHERE trigger_schema = 'public'
ORDER BY trigger_name, event;
