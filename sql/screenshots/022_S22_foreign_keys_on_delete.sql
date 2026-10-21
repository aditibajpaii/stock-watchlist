SELECT tc.table_name, rc.constraint_name, rc.delete_rule
FROM information_schema.referential_constraints rc
JOIN information_schema.table_constraints tc ON tc.constraint_name = rc.constraint_name
WHERE rc.constraint_schema = 'public'
ORDER BY rc.delete_rule, tc.table_name;
