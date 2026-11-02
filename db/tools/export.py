#!/usr/bin/env python3
"""Export PostgreSQL schema and allowlisted master data into db/ for agents that must not touch the database.

Runs ONLY inside the trusted network (nightly job or an engineer's workstation) with a read-only role.
Connection comes from standard libpq env vars (PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSFILE or
PGPASSWORD, PGSSLMODE). Standard library only; needs pg_dump/psql whose major version >= the server's.

Exit codes: 0 = no changes, 10 = artifacts changed (open a PR), 1 = error.
Usage: python3 db/tools/export.py [--dbml] [--report db/out/db_sync_report.md]
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

sys.path.insert(0, str(Path(__file__).resolve().parent))
from diff import diff_catalog, diff_master  # noqa: E402

DB_DIR = Path(__file__).resolve().parents[1]
CONFIG = DB_DIR / "config" / "export.config.json"
SCHEMA_DIR = DB_DIR / "schema"
MASTER_DIR = DB_DIR / "master"


def env() -> dict:
    e = dict(os.environ)
    e["PGAPPNAME"] = "db-export"
    e["PGCLIENTENCODING"] = "UTF8"
    # Deterministic text output for dates/times regardless of server or runner defaults.
    e["PGOPTIONS"] = "-c TimeZone=UTC -c DateStyle=ISO,YMD -c default_transaction_read_only=on -c statement_timeout=300000"
    return e


def run(cmd: list[str]) -> bytes:
    res = subprocess.run(cmd, env=env(), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if res.returncode != 0:
        sys.stderr.write(res.stderr.decode(errors="replace"))
        raise SystemExit(f"command failed: {cmd[0]} (exit {res.returncode})")
    return res.stdout


def psql(sql: str) -> str:
    return run(["psql", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-c", sql]).decode().strip()


def qi(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def check_versions() -> dict:
    server = int(psql("SHOW server_version_num"))
    dump_ver = run(["pg_dump", "--version"]).decode()
    m = re.search(r"(\d+)\.(\d+)", dump_ver)
    client_major = int(m.group(1)) if m else 0
    if client_major < server // 10000:
        raise SystemExit(f"pg_dump {client_major} is older than server {server // 10000}; install a newer client")
    has_restrict = "--restrict-key" in run(["pg_dump", "--help"]).decode()
    return {"serverVersionNum": server, "pgDump": dump_ver.strip(), "restrictKeySupported": has_restrict}


def dump_schema(cfg: dict, versions: dict) -> bytes:
    cmd = ["pg_dump", "--schema-only", "--no-owner", "--no-privileges", "--no-tablespaces",
           "--no-security-labels", "--lock-wait-timeout=5000"]
    if versions["restrictKeySupported"]:
        cmd.append(f"--restrict-key={cfg['restrictKey']}")
    for s in cfg["schemas"]:
        cmd += ["-n", s]
    for pattern in cfg.get("excludeTablePatterns", []):
        cmd += ["-T", pattern]
    text = run(cmd).decode()
    # Drop lines that change on every minor upgrade; versions go in the report instead.
    text = re.sub(r"^-- Dumped (from database|by pg_dump) version .*\n", "", text, flags=re.M)
    return text.encode()


def export_catalog(cfg: dict) -> dict:
    out = run(["psql", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1",
               "-v", f"schemas={','.join(cfg['schemas'])}", "-f", str(DB_DIR / "tools" / "catalog.sql")])
    return json.loads(out)


def primary_key(table: dict) -> list[str]:
    for c in table["constraints"]:
        if c["type"] == "p":
            inner = re.search(r"PRIMARY KEY \((.*)\)", c["definition"])
            if inner:
                return [x.strip().strip('"') for x in inner.group(1).split(",")]
    return []


def export_master(cfg: dict, catalog: dict) -> tuple[dict[str, bytes], list[dict]]:
    tables = {f"{t['schema']}.{t['name']}": t for t in catalog["tables"]}
    pii = re.compile(cfg["piiColumnPattern"].replace("(?i)", ""), re.I)
    limits = cfg["limits"]
    files: dict[str, bytes] = {}
    entries: list[dict] = []
    for spec in cfg["master"]:
        fq = spec["table"]
        if fq not in tables:
            raise SystemExit(f"master table {fq} not found in exported schemas")
        t = tables[fq]
        excluded = set(spec.get("excludeColumns", []))
        unknown = excluded - {c["name"] for c in t["columns"]}
        if unknown:
            raise SystemExit(f"{fq}: excludeColumns not in table: {sorted(unknown)}")
        cols = [c for c in t["columns"] if c["name"] not in excluded and not c.get("generated")]
        flagged = [c["name"] for c in cols if pii.search(c["name"])]
        if flagged and not spec.get("piiReviewed"):
            raise SystemExit(f"{fq}: columns look personal/sensitive {flagged}; exclude them or set piiReviewed after review")
        order = spec.get("orderBy") or primary_key(t)
        if not order:
            raise SystemExit(f"{fq}: no orderBy and no primary key; exports must be deterministic")
        schema, name = fq.split(".", 1)
        select = ", ".join(qi(c["name"]) for c in cols)
        sql = (f"COPY (SELECT {select} FROM {qi(schema)}.{qi(name)} ORDER BY {', '.join(qi(c) for c in order)}) "
               f"TO STDOUT WITH (FORMAT csv, HEADER true)")
        data = run(["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-c", sql])
        rows = sum(1 for _ in csv.reader(io.StringIO(data.decode("utf-8"), newline=""))) - 1
        if rows > limits["maxRowsPerTable"]:
            raise SystemExit(f"{fq}: {rows} rows exceeds maxRowsPerTable; is this really master data?")
        if len(data) > limits["maxBytesPerFile"]:
            raise SystemExit(f"{fq}: {len(data)} bytes exceeds maxBytesPerFile")
        file_name = f"{fq}.csv"
        files[file_name] = data
        entries.append({
            "table": fq, "file": file_name, "rows": rows, "sha256": hashlib.sha256(data).hexdigest(),
            "orderBy": order, "columns": [{"name": c["name"], "type": c["type"]} for c in cols],
            "excludedColumns": sorted(excluded), "classification": spec.get("classification", "unclassified"),
        })
    return files, entries


def export_dbml(cfg: dict, out: Path) -> None:
    # Official @dbml/cli; pin it as a devDependency in production use. The connection string is
    # assembled from libpq env vars because db2dbml only accepts a URL.
    e = os.environ
    url = (f"postgresql://{quote(e['PGUSER'], safe='')}:{quote(e.get('PGPASSWORD', ''), safe='')}@{e['PGHOST']}:{e.get('PGPORT', '5432')}/"
           f"{e['PGDATABASE']}?schemas={','.join(cfg['schemas'])}")
    res = subprocess.run(["npx", "--yes", "-p", "@dbml/cli", "db2dbml", "postgres", url, "-o", str(out)],
                         stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if res.returncode != 0:
        raise SystemExit("db2dbml failed: " + res.stderr.decode(errors="replace").replace(e.get("PGPASSWORD", "") or "\0", "***"))


def write_if_changed(path: Path, data: bytes) -> bool:
    if path.exists() and path.read_bytes() == data:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return True


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dbml", action="store_true", help="also regenerate schema/schema.dbml via @dbml/cli")
    ap.add_argument("--report", default=str(DB_DIR / "out" / "db_sync_report.md"))
    args = ap.parse_args()

    cfg = json.loads(CONFIG.read_text())
    versions = check_versions()

    old_catalog = json.loads((SCHEMA_DIR / "catalog.json").read_text()) if (SCHEMA_DIR / "catalog.json").exists() else {}
    old_master = {p.name: p.read_bytes() for p in MASTER_DIR.glob("*.csv")}

    schema_sql = dump_schema(cfg, versions)
    catalog = export_catalog(cfg)
    master_files, master_entries = export_master(cfg, catalog)

    changed: list[str] = []
    if write_if_changed(SCHEMA_DIR / "schema.sql", schema_sql):
        changed.append("schema/schema.sql")
    if write_if_changed(SCHEMA_DIR / "catalog.json", (json.dumps(catalog, indent=2, sort_keys=True) + "\n").encode()):
        changed.append("schema/catalog.json")
    for name, data in master_files.items():
        if write_if_changed(MASTER_DIR / name, data):
            changed.append(f"master/{name}")
    for stale in sorted(set(old_master) - set(master_files)):
        (MASTER_DIR / stale).unlink()
        changed.append(f"master/{stale} (removed)")
    manifest = {"formatVersion": 1, "schemas": cfg["schemas"], "tables": master_entries}
    if write_if_changed(MASTER_DIR / "manifest.json", (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()):
        changed.append("master/manifest.json")
    if args.dbml:
        export_dbml(cfg, SCHEMA_DIR / "schema.dbml")
        changed.append("schema/schema.dbml (regenerated)")

    schema_changes = diff_catalog(old_catalog, catalog) if old_catalog else ["Initial export"]
    lines = [
        "# Nightly database export report",
        "",
        f"- Run at: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}",
        f"- Server version: {versions['serverVersionNum']}; client: {versions['pgDump']}",
        f"- Schemas: {', '.join(cfg['schemas'])}",
        f"- Files changed: {len([c for c in changed if 'regenerated' not in c])}",
        "",
        "## 1. Schema changes",
        "",
        *([f"- {c}" for c in schema_changes] or ["- None"]),
        "",
        "## 2. Master data changes",
        "",
    ]
    any_master = False
    for e in master_entries:
        delta = diff_master(old_master.get(e["file"]), master_files[e["file"]], e["orderBy"])
        if delta:
            any_master = True
            lines.append(f"### `{e['table']}` ({e['rows']} rows)")
            lines += [f"- {d}" for d in delta] + [""]
    if not any_master:
        lines.append("- None")
    lines += ["", "## 3. Action", "",
              "Review and merge the PR if these changes were intended. If not, raise them with the owning team "
              "before the next release; the repository is what agents build against.", ""]
    Path(args.report).parent.mkdir(parents=True, exist_ok=True)
    Path(args.report).write_text("\n".join(lines))

    real_changes = [c for c in changed if "regenerated" not in c]
    print(f"export complete; {len(real_changes)} file(s) changed; report: {args.report}")
    return 10 if real_changes else 0


if __name__ == "__main__":
    sys.exit(main())
