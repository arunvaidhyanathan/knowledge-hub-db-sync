# knowledge-hub-db-sync

Exports the schema and allowlisted master tables of the Supabase PostgreSQL database into `db/` as files
(`db/schema/schema.sql`, `db/schema/catalog.json`, `db/master/*.csv`, `db/master/manifest.json`).

The export is **read-only**: it runs in one read-only transaction. Nothing is dropped, created or written
in the database.

Pure Python: the only dependency is `psycopg` (`requirements.txt`), which bundles libpq. No `pg_dump`,
`psql` or Postgres client install is needed. `schema.sql` is generated from the live catalog by
`db/tools/ddl.py` using the server's own `pg_get_*` functions. Against this database it produces the same
statements as `pg_dump --schema-only --no-owner --no-privileges`. Partitions are skipped (parents kept),
and objects it cannot reproduce (domains, composite/range types, aggregates, operators, inheritance,
foreign tables, rules) stop the export with an error rather than being left out.

## Setup

1. Python 3.10+.
2. `cp .env.example .env` and set `PGPASSWORD` (raw password, no percent-encoding).

`./run.sh` creates `.venv` and installs `requirements.txt` on first run.

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

Each master table is one entry in the "master" array, written as schema.table. The table's schema must also be in the "schemas" list. Here is an example:

{
  "version": 1,
  "schemas": ["public", "ref"],
  "excludeTablePatterns": [],
  "extensions": [],
  "restrictKey": "dbexport",
  "piiColumnPattern": "(?i)(email|phone|mobile|ssn|tax_?id|dob|birth|address|account_?(no|num)|card|salary|passport)",
  "limits": { "maxRowsPerTable": 50000, "maxBytesPerFile": 10485760 },
  "master": [
    {
      "table": "ref.country",
      "orderBy": ["iso_code"],
      "classification": "reference"
    },
    {
      "table": "public.tenants",
      "orderBy": ["id"],
      "excludeColumns": ["internal_note"],
      "classification": "reference"
    },
    {
      "table": "ref.workflow_status",
      "orderBy": ["id"],
      "classification": "reference",
      "tsEnum": { "name": "WorkflowStatus", "key": "code", "label": "label" }
    }
  ],
  "tsOutput": "frontend/src/generated/master-data.ts"
}

Fields for each entry

┌────────────────┬──────────┬───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│     Field      │ Required │                                                                                                 What it does                                                                                                  │
├────────────────┼──────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ table          │ yes      │ schema.table. The export stops if the table doesn't exist.                                                                                                                                                    │
├────────────────┼──────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ orderBy        │ no       │ Columns used to sort rows, so the CSV is the same on every run. If you leave it out, the primary key is used. If the table has neither, the export stops.                                                     │
├────────────────┼──────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ excludeColumns │ no       │ Columns left out of the CSV. Every name must exist in the table.                                                                                                                                              │
├────────────────┼──────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ classification │ no       │ A label recorded in the manifest, for example reference.                                                                                                                                                      │
├────────────────┼──────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ piiReviewed    │ no       │ Set to true only after you've checked the columns. Without it, any column whose name matches piiColumnPattern (email, phone, address and so on) stops the export. You can also exclude those columns instead. │
├────────────────┼──────────┼───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ tsEnum         │ no       │ Generates a TypeScript constant from the table: key is the column used for the constant names and label the column used for display text. It's only used by gen_ts_enums.py, so most tables can skip it.      │
└────────────────┴──────────┴───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

Limits: a table with more than 50,000 rows, or a CSV larger than 10 MB, stops the export. That keeps transactional tables from being exported as master data by mistake.

Output: each table becomes db/master/<schema>.<table>.csv, and its row count and checksum are recorded in manifest.json.

All you need to send me is the schema, the table name, and any columns to exclude. For example:

ref.country (exclude internal_note)
public.tenants
