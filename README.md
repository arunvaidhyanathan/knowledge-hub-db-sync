# knowledge-hub-db-sync

Exports the schema and allowlisted master tables of the Supabase PostgreSQL database into `db/` as files
(`db/schema/schema.sql`, `db/schema/catalog.json`, `db/master/*.csv`, `db/master/manifest.json`).

The export is **read-only**: sessions run with `default_transaction_read_only=on`. Nothing is dropped,
created or written in the database.

## Setup

1. Install a Postgres client at least as new as the server (Supabase is on Postgres 15):
   `brew install libpq` (puts `pg_dump`/`psql` in `/opt/homebrew/opt/libpq/bin`, which `.env` points to via `PG_BIN`).
2. `cp .env.example .env` and set `PGPASSWORD` (raw password, no percent-encoding).

## Run

```bash
./run.sh            # schema + master data
./run.sh --dbml     # also writes db/schema/schema.dbml (needs Node/npx)
```

Exit code 0 = no changes, 10 = files changed (see `db/out/db_sync_report.md`), anything else = error.

## Configure what is exported

`db/config/export.config.json`:

- `schemas`: schemas to export (default `public`).
- `master`: allowlisted master tables, e.g.
  `{ "table": "public.country", "orderBy": ["iso_code"], "classification": "reference" }`.
  Optional: `excludeColumns`, `piiReviewed`, `tsEnum`.

Design notes: `docs/implementation/db-schema-sync.md`.
