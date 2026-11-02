#!/usr/bin/env bash
# Export schema + master data from the database configured in .env. Read-only: no DROP/CREATE/INSERT.
# Usage: ./run.sh [--dbml]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

[ -f .env ] || { echo "Missing .env (copy .env.example and set PGPASSWORD)" >&2; exit 1; }
set -a; . ./.env; set +a
[ -n "${PGPASSWORD:-}" ] || { echo "PGPASSWORD is empty in .env" >&2; exit 1; }
if [ -n "${PG_BIN:-}" ] && [ -d "$PG_BIN" ]; then export PATH="$PG_BIN:$PATH"; fi

set +e
python3 db/tools/export.py "$@"
code=$?
set -e
case $code in
  0)  echo "No changes." ;;
  10) echo "Files changed under db/schema and db/master. Report: db/out/db_sync_report.md" ;;
  *)  exit "$code" ;;
esac
