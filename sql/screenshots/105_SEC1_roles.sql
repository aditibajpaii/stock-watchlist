SELECT rolname, rolcanlogin, rolsuper
FROM pg_roles
WHERE rolname IN ('sw_admin', 'sw_analyst', 'sw_enduser', 'arjun', 'priya');
\drg
