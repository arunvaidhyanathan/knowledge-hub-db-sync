# Product Requirements Document (PRD)
## Automated Nightly DB Schema & Master Data Synchronization Engine

---

## 1. Executive Summary
This document defines the requirements, architecture, and step-by-step implementation for integrating a **Database & Contract Validation Engine** into the existing **nightly CI/CD build pipeline**. 

The goal is to maintain single-source-of-truth metadata (`.dbml` for schemas, `.jsonl` for master data) in the repository without granting external third-party access (such as Devin AI cloud agents) directly to production or staging PostgreSQL instances. The pipeline introspects the live database, detects schema/data drift, verifies alignment with Spring Boot entities and React/TypeScript types, and produces an actionable Markdown report for morning engineering reviews.

---

## 2. System Architecture & CI/CD Pipeline Flow

```
[ Existing Nightly CI/CD Pipeline ]
                  │
                  ▼
   ┌──────────────────────────────┐
   │ 1. Introspect Live PostgreSQL│ ──► Export DBML & JSONL (in-memory/temp)
   └──────────────┬───────────────┘
                  │
                  ▼
   ┌──────────────────────────────┐
   │ 2. Run Validation Script     │ ──► Schema Diff, Master Hash Check, Contract Check
   └──────────────┬───────────────┘
                  │
                  ▼
   ┌──────────────────────────────┐
   │ 3. Discrepancy Reporting     │ ──► Generate Markdown Artifact / Publish PR Summary
   └──────────────────────────────┘
```

### Key Components:
1. **Repository Context (`db/` Directory):**
   * `db/schema.dbml`: Expected schema structure in compact, token-efficient DBML format.
   * `db/master/*.jsonl`: Master table reference datasets in line-delimited JSON.
   * `db/manifest.json`: Precomputed MD5/SHA256 hashes of master tables for fast validation.
2. **CI/CD Integration Layer:** A dedicated validation step inserted into your existing nightly pipeline build job.
3. **Report Generator:** Outputs a structured Markdown discrepancy report as a build artifact and optional pull-request/issue summary.

---

## 3. Pipeline Step Requirements

### Step 3.1: Database Extraction (In-Memory / Runner Local)
The pipeline runner extracts metadata without modifying the live PostgreSQL database.

* **Schema Extraction:** Convert live PostgreSQL DDL directly to DBML format using `@dbml/cli` or a custom DBML converter script.
  ```bash
  # Extracts schema directly from target PostgreSQL instance to a temp runner file
  npx @dbml/cli db2dbml postgres "$DATABASE_READONLY_URL" -o /tmp/live_schema.dbml
  ```
* **Master Table Extraction:** Export rows from registered static lookup tables into JSONL format.
  ```bash
  # Example psql extraction for master tables
  psql "$DATABASE_READONLY_URL" -t -A -c \
    "SELECT row_to_json(t) FROM master_order_statuses t" > /tmp/master_order_statuses.jsonl
  ```

### Step 3.2: Multi-Layer Validation Logic

| Layer | Validation Target | Target Format | Validation Logic |
| :--- | :--- | :--- | :--- |
| **Layer 1: Schema Integrity** | Live DB vs Repository | `schema.dbml` | Structural diff of tables, columns, constraints, foreign keys, and column data types. |
| **Layer 2: Master Data Sync** | Live DB vs Repository | `master/*.jsonl` | Line-by-line comparison and row-count/checksum verification against `manifest.json`. |
| **Layer 3: Backend Contract** | Spring Boot JPA | `@Entity`, `@Column` | Scan Java Spring Boot classes to ensure model annotations match actual DB column constraints. |
| **Layer 4: Frontend Contract** | React/TypeScript | `.ts` / `.tsx` types | Compare TypeScript interface declarations with DTO definitions and master key values. |

---

## 4. Implementation Details for CI/CD Integration

### 4.1 CLI Validator Script (`scripts/validate_db_sync.py`)

Include a lightweight, zero-dependency validation script in your repository:

```python
#!/usr/bin/env python3
import os
import json
import hashlib
import sys

def calculate_file_hash(filepath):
    """Calculates SHA256 of normalized text file."""
    hasher = hashlib.sha256()
    if not os.path.exists(filepath):
        return None
    with open(filepath, 'rb') as f:
        for chunk in iter(lambda: f.read(4096), os.devbytes):
            hasher.update(chunk)
    return hasher.hexdigest()

def compare_dbml(repo_dbml, live_dbml):
    """Simple diff engine for DBML structure."""
    with open(repo_dbml, 'r') as f1, open(live_dbml, 'r') as f2:
        repo_lines = set(line.strip() for line in f1 if line.strip() and not line.startswith("//"))
        live_lines = set(line.strip() for line in f2 if line.strip() and not line.startswith("//"))

    missing_in_repo = live_lines - repo_lines
    missing_in_live = repo_lines - live_lines

    return missing_in_repo, missing_in_live

def main():
    repo_schema = "db/schema.dbml"
    live_schema = "/tmp/live_schema.dbml"
    
    report = []
    has_errors = False

    report.append("# 🔍 Nightly Database & Application Sync Report\n")

    # 1. Schema Check
    if not os.path.exists(live_schema):
        report.append("❌ **CRITICAL**: Live DBML extraction failed or file not found.\n")
        sys.exit(1)

    missing_repo, missing_live = compare_dbml(repo_schema, live_schema)
    
    if not missing_repo and not missing_live:
        report.append("### 1. Schema Drift Check: ✅ In Sync\n")
    else:
        has_errors = True
        report.append("### 1. Schema Drift Check: ❌ Discrepancies Found\n")
        if missing_repo:
            report.append("**Live DB changes missing in `db/schema.dbml`:**")
            for line in missing_repo:
                report.append(f"- `{line}`")
        if missing_live:
            report.append("\n**`db/schema.dbml` definitions missing in Live DB:**")
            for line in missing_live:
                report.append(f"- `{line}`")
        report.append("")

    # Write report artifact
    with open("db_sync_report.md", "w") as f:
        f.write("\n".join(report))

    if has_errors:
        print("Validation completed with discrepancies. See db_sync_report.md.")
        sys.exit(1)
    else:
        print("Validation successful. Everything is in sync.")
        sys.exit(0)

if __name__ == "__main__":
    main()
```

### 4.2 CI/CD Step Configuration (e.g., GitHub Actions / GitLab CI / Jenkins)

Add the following execution block to your existing **Nightly Pipeline**:

```yaml
  validate-db-sync:
    name: Validate DB & Schema Alignment
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Setup Node.js (for DBML CLI)
        uses: actions/setup-node@v4
        with:
          node-version: '20'

      - name: Introspect Database & Dump DBML
        env:
          DATABASE_READONLY_URL: ${{ secrets.NIGHTLY_READONLY_DB_URL }}
        run: |
          npx @dbml/cli db2dbml postgres "$DATABASE_READONLY_URL" -o /tmp/live_schema.dbml

      - name: Run Schema and Data Validation Script
        run: |
          python3 scripts/validate_db_sync.py

      - name: Upload Discrepancy Report Artifact
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: db-sync-report
          path: db_sync_report.md
```

---

## 5. Output Discrepancy Report Format

When discrepancies are detected during the nightly build, the generated `db_sync_report.md` will structure issues as follows:

```markdown
# 🔍 Nightly Database & Application Sync Report
* **Execution Timestamp:** 2026-11-02 02:30:15 UTC
* **Pipeline ID:** `#89421-nightly`

### 1. Schema Drift Check: ❌ Discrepancies Found
**Live DB changes missing in `db/schema.dbml`:**
- `Table users { status_id integer }`
- `Ref: users.status_id > master_user_statuses.id`

### 2. Master Data Sync Check: ❌ Discrepancies Found
- **Table `master_order_statuses`**: Key `PARTIALLY_REFUNDED` present in live database, but missing in `db/master/master_order_statuses.jsonl`.

### 3. Application Type Alignment (Spring Boot / TypeScript): ⚠️ Warning
- `UserDTO.java`: Field `statusId` present in Spring Boot DTO but missing in React `UserTypes.ts`.

---
*Action Required: Update repository `.dbml` / `.jsonl` files via PR if database updates were intentional.*
```

---

## 6. Token & Performance Optimization Strategies
1. **DBML vs raw SQL:** Using DBML reduces file size by up to ~65% compared to standard DDL dumps, drastically cutting token footprint for Devin/AI context windows.
2. **JSONL for Master Data:** Line-delimited JSON enables line-by-line hashing and differential parsing, preventing memory bloat in CI runners.
3. **MD5 Checksum Manifest:** Master tables are evaluated via precomputed hashes in `db/manifest.json`. Data files are only parsed if the cryptographic checksum changes.