SELECT grantee, table_schema, table_name, string_agg(privilege_type, ', ') AS privileges
FROM information_schema.role_table_grants
WHERE grantee IN ('sw_admin', 'sw_analyst', 'sw_enduser')
GROUP BY grantee, table_schema, table_name
ORDER BY grantee, table_name;
