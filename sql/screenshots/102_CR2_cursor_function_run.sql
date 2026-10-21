\echo '========================================================================'
\echo ' CR2 | Cursor 1 (run): the cursor walks each user''s rules one row at a time'
\echo '========================================================================'
SELECT * FROM reporting.fn_rule_status_report('arjun');
SELECT * FROM reporting.fn_rule_status_report('priya');
SELECT * FROM reporting.fn_rule_status_report('kavya');
