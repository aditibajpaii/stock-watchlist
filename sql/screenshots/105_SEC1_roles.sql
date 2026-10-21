\echo '========================================================================'
\echo ' SEC1 | Roles created by sql/09_review2_objects.sql'
\echo '        3 group roles (admin / analyst / end user) + 2 end-user logins'
\echo '========================================================================'
SELECT r.rolname AS role, r.rolcanlogin AS can_login, r.rolsuper AS superuser,
       coalesce((SELECT string_agg(g.rolname, ', ')
                 FROM pg_auth_members m JOIN pg_roles g ON g.oid = m.roleid
                 WHERE m.member = r.oid), '') AS member_of
FROM pg_roles r
WHERE r.rolname IN ('sw_admin', 'sw_analyst', 'sw_enduser', 'arjun', 'priya')
ORDER BY r.rolcanlogin, r.rolname;
