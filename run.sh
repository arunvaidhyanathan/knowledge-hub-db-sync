#!/usr/bin/env bash
# Export schema + master data from the database configured in .env. Read-only: no DROP/CREATE/INSERT.
# Usage: ./run.sh [--dbml]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

[ -f .env ] || { echo "Missing .env (copy .env.example and set PGPASSWORD)" >&2; exit 1; }
set -a; . ./.env; set +a
[ -n "${PGPASSWORD:-}" ] || { echo "PGPASSWORD is empty in .env" >&2; exit 1; }

# Python virtual environment with psycopg (bundles libpq; no Postgres client install needed).
if [ ! -x .venv/bin/python ]; then
  python3 -m venv .venv
fi
if ! .venv/bin/python -c 'import psycopg' 2>/dev/null; then
  .venv/bin/pip install -q -r requirements.txt
fi

set +e
.venv/bin/python db/tools/export.py "$@"
code=$?
set -e
case $code in
  0)  echo "No changes." ;;
  10) echo "Files changed under db/schema and db/master. Report: db/out/db_sync_report.md" ;;
  *)  exit "$code" ;;
esac
