# Research Decision Brief

Confirmed findings only. Do not add claims here that were not part of the
research.

## Platform

- PostgreSQL 18 chosen as the DBMS.

## Price tick identity and indexing

- Use a surrogate `tick_id` for price tick identity.
- Never assume timestamp uniqueness.
- Composite B-tree index for one-instrument time-range / latest queries.
- BRIN: optional, later comparison only.
- Partitioning: optional benchmark only, not part of the core schema.

## Alerts

- Alerts are edge-triggered (fire on crossing, not while staying past).
- ABOVE and BELOW directions.
- Cooldown per rule.
- Database-level duplicate protection (constraints as final safety net).

## Transactions and concurrency

- READ COMMITTED for normal operation, with explicit row locking and
  constraints providing correctness.
- SERIALIZABLE only as a later experiment/demonstration.

## Deletion policy

- CASCADE only for genuine ownership relationships.
- RESTRICT for instrument -> price history.

## Data sources

- Offline replay is the guaranteed demo source.
- Binance / live feed is optional.

## Out of scope

- Trading / order execution
- Portfolio accounting
- ML / price prediction
- Kafka (and similar streaming infrastructure)
- TimescaleDB dependency
- Complicated frontend
