\echo '========================================================================'
\echo ' F5 | Function: string functions'
\echo '      Q: Build display labels and split identifiers into parts'
\echo '========================================================================'
SELECT upper(username)                  AS upper_name,
       initcap(username)                AS display_name,
       length(email)                    AS email_length,
       split_part(email, '@', 2)        AS email_domain,
       username || ' <' || email || '>' AS contact
FROM users ORDER BY user_id;

SELECT concat(exchange, ':', symbol)          AS ticker,
       lower(symbol)                          AS lower_symbol,
       replace(name, ' Ltd', '')              AS short_name,
       left(name, 12)                         AS first_12,
       format('%s (%s)', symbol, quote_currency) AS label
FROM instruments ORDER BY instrument_id;

SELECT source_event_id,
       split_part(source_event_id, ':', 1)      AS run_id,
       split_part(source_event_id, ':', 2)::int AS row_no
FROM price_ticks WHERE instrument_id = 7;
