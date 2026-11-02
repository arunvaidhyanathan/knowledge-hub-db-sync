#!/usr/bin/env python3
"""Structured diffs for catalog.json and master CSV files. Standard library only.

CLI: python3 db/tools/diff.py OLD_CATALOG.json NEW_CATALOG.json
"""
from __future__ import annotations

import csv
import io
import json
import sys


def _index(items, key):
    return {key(i): i for i in items or []}


def diff_catalog(old: dict, new: dict) -> list[str]:
    out: list[str] = []
    if old.get("serverMajorVersion") != new.get("serverMajorVersion"):
        out.append(f"CHANGED server major version {old.get('serverMajorVersion')} -> {new.get('serverMajorVersion')}")

    def table_key(t):
        return f"{t['schema']}.{t['name']}"

    ot, nt = _index(old.get("tables"), table_key), _index(new.get("tables"), table_key)
    for k in sorted(nt.keys() - ot.keys()):
        out.append(f"ADDED {nt[k]['kind']} `{k}` ({len(nt[k]['columns'])} columns)")
    for k in sorted(ot.keys() - nt.keys()):
        out.append(f"REMOVED {ot[k]['kind']} `{k}`")
    for k in sorted(ot.keys() & nt.keys()):
        o, n = ot[k], nt[k]
        oc, nc = _index(o["columns"], lambda c: c["name"]), _index(n["columns"], lambda c: c["name"])
        for c in sorted(nc.keys() - oc.keys()):
            col = nc[c]
            out.append(f"ADDED column `{k}.{c}` {col['type']}{' NOT NULL' if col['notNull'] else ''}")
        for c in sorted(oc.keys() - nc.keys()):
            out.append(f"REMOVED column `{k}.{c}`")
        for c in sorted(oc.keys() & nc.keys()):
            for attr in ("type", "notNull", "default", "identity", "generated"):
                if oc[c].get(attr) != nc[c].get(attr):
                    out.append(f"CHANGED column `{k}.{c}` {attr}: {oc[c].get(attr)!r} -> {nc[c].get(attr)!r}")
        labels = {"constraints": "constraint", "indexes": "index", "triggers": "trigger", "policies": "policy"}
        for section, label in labels.items():
            od, nd = _index(o.get(section), lambda x: x["name"]), _index(n.get(section), lambda x: x["name"])
            for x in sorted(nd.keys() - od.keys()):
                out.append(f"ADDED {label} `{k}.{x}`: {nd[x].get('definition', '')}")
            for x in sorted(od.keys() - nd.keys()):
                out.append(f"REMOVED {label} `{k}.{x}`")
            for x in sorted(od.keys() & nd.keys()):
                if od[x] != nd[x]:
                    out.append(f"CHANGED {label} `{k}.{x}`: {od[x].get('definition', od[x])} -> {nd[x].get('definition', nd[x])}")
        if o.get("viewDefinitionMd5") != n.get("viewDefinitionMd5"):
            out.append(f"CHANGED view definition `{k}`")
        if o.get("rowSecurity") != n.get("rowSecurity"):
            out.append(f"CHANGED row security `{k}`: {o.get('rowSecurity')} -> {n.get('rowSecurity')}")

    def named(section, key, describe):
        od, nd = _index(old.get(section), key), _index(new.get(section), key)
        for x in sorted(nd.keys() - od.keys()):
            out.append(f"ADDED {describe} `{x}`")
        for x in sorted(od.keys() - nd.keys()):
            out.append(f"REMOVED {describe} `{x}`")
        for x in sorted(od.keys() & nd.keys()):
            if od[x] != nd[x]:
                changed = sorted(a for a in set(od[x]) | set(nd[x]) if od[x].get(a) != nd[x].get(a))
                detail = ", ".join(
                    f"{a}: {od[x].get(a)!r} -> {nd[x].get(a)!r}" if not a.endswith("Md5") else f"{a} changed"
                    for a in changed)
                out.append(f"CHANGED {describe} `{x}`: {detail}")

    named("enums", lambda e: f"{e['schema']}.{e['name']}", "enum")
    named("sequences", lambda s: f"{s['schema']}.{s['name']}", "sequence")
    named("functions", lambda f: f"{f['schema']}.{f['name']}({f['arguments']})", "function")
    named("extensions", lambda e: e["name"], "extension")
    return out


def read_csv(data: bytes | None) -> tuple[list[str], list[dict]]:
    if not data:
        return [], []
    reader = csv.DictReader(io.StringIO(data.decode("utf-8"), newline=""))
    return list(reader.fieldnames or []), list(reader)


def diff_master(old: bytes | None, new: bytes, key_cols: list[str], limit: int = 25) -> list[str]:
    o_cols, o_rows = read_csv(old)
    n_cols, n_rows = read_csv(new)
    out: list[str] = []
    if old is None:
        return [f"NEW table export ({len(n_rows)} rows)"]
    if o_cols != n_cols:
        out.append(f"COLUMNS {o_cols} -> {n_cols}")

    def key(r):
        return "|".join(str(r.get(c)) for c in key_cols)

    oi, ni = {key(r): r for r in o_rows}, {key(r): r for r in n_rows}
    added = sorted(ni.keys() - oi.keys())
    removed = sorted(oi.keys() - ni.keys())
    changed = sorted(k for k in oi.keys() & ni.keys() if oi[k] != ni[k])
    for label, keys in (("ADDED", added), ("REMOVED", removed), ("CHANGED", changed)):
        if keys:
            shown = ", ".join(f"`{k}`" for k in keys[:limit])
            more = f" and {len(keys) - limit} more" if len(keys) > limit else ""
            out.append(f"{label} {len(keys)} row(s) by key ({', '.join(key_cols)}): {shown}{more}")
    return out


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: diff.py OLD_CATALOG.json NEW_CATALOG.json")
    with open(sys.argv[1]) as f1, open(sys.argv[2]) as f2:
        changes = diff_catalog(json.load(f1), json.load(f2))
    print("\n".join(changes) if changes else "no schema changes")
    sys.exit(1 if changes else 0)
