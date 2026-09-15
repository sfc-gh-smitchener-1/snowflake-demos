# Sutter Health — Healthcare Claims Intelligence Demo

## Overview

This demo showcases Snowflake's Data Cloud Architecture (DCA) applied to a real-world health plan
claims processing and risk adjustment scenario. It is scoped for a Sutter Health discovery/proof-of-concept
engagement and highlights:

- **Healthcare Claims Data Model** — Five production-grade tables covering raw claims, member
  enrollment, provider directory, risk adjustment flags, and claims summary
- **Risk Adjustment Pipeline** — A stored procedure that runs daily, applies HCC risk category
  logic to ICD-10 diagnosis codes, flags 24-hour SLA breaches, and writes a timestamped run table
- **Cortex AI Natural Language** — Semantic views powering Cortex Analyst so business users can
  ask plain-English questions against claims and risk data
- **Cost Comparison** — Quantified Snowflake vs always-on Databricks cluster cost for the same
  daily pipeline workload
- **Before/After Architecture** — Two-panel diagram showing the legacy Epic → Milliman → SQL
  Server → Qlik stack vs the modern Snowflake streaming + Cortex AI path

## Prerequisites

- Snowflake account with the DCA base layer deployed (run `sql/01_setup.sql` through `sql/05_curated_layer.sql`
  at the repo root first)
- Roles: `DATA_ADMIN` (to run setup), `SYSADMIN` (for warehouse creation if needed)
- Python 3.9+ with `faker`, `snowflake-connector-python`, `pandas` installed
- Warehouses: `COMPUTE_WH` (XS), `TRANSFORM_WH` (S), `ANALYTICS_WH` (S)

## Run Order

```
# 1. Generate sample data (1,000 members, ~12,000 claims, last 12 months)
cd tools/
python generate_sh_claims_data.py --output ../data

# 2. Deploy all SQL in order
cd ../sql/
snowsql -f 01_sh_setup.sql
snowsql -f 02_sh_claims_model.sql
snowsql -f 03_sh_load_data.sql      # uploads CSVs then runs COPY INTO
snowsql -f 04_sh_curated_layer.sql
snowsql -f 05_sh_risk_adjustment_sp.sql
snowsql -f 06_sh_semantic_layer.sql
snowsql -f 07_sh_cost_comparison.sql

# Or use the automated deployer:
cd tools/
python deploy.py
```

## Quick-Start (test data only)

```bash
python tools/generate_sh_claims_data.py --quick --output data/
```
Generates a 10% sample (~100 members, ~1,200 claims) for rapid iteration.

## Demo Flow

| Step | What to show | Talking point |
|------|-------------|---------------|
| 1 | `02_sh_claims_model.sql` schema | "Production columns including SLA timestamps out of the box" |
| 2 | `CALL SP_SH_RISK_ADJUSTMENT_DAILY_RUN(CURRENT_DATE())` | "What Milliman does in days, Snowflake does in seconds on an XS warehouse" |
| 3 | Cortex Analyst NL queries in `06_sh_semantic_layer.sql` | "Any analyst can ask in plain English — no SQL required" |
| 4 | `07_sh_cost_comparison.sql` result | "Always-on Databricks cluster costs 40× more for this workload" |
| 5 | `architecture/before_after_architecture.html` | "24-hour lag → near-real-time, same clinical source data" |

## File Inventory

```
sql/
  01_sh_setup.sql               Schemas, roles, governance tags
  02_sh_claims_model.sql        Raw table DDL (5 tables)
  03_sh_load_data.sql           Stage + COPY INTO
  04_sh_curated_layer.sql       Dynamic Tables (curated layer)
  05_sh_risk_adjustment_sp.sql  Daily risk adjustment stored procedure
  06_sh_semantic_layer.sql      Semantic views + Cortex Analyst test
  07_sh_cost_comparison.sql     Snowflake vs Databricks cost table
tools/
  generate_sh_claims_data.py    Synthetic data generator (1k members)
  deploy.py                     End-to-end deployment script
architecture/
  before_after_architecture.html  Two-panel architecture diagram
data/                           Generated CSVs land here (gitignored)
```

## Key Demo Stats (full scale)

| Metric | Value |
|--------|-------|
| Members | 1,000 |
| Claims (12 months) | ~12,000 |
| Providers | 200 |
| HCC risk categories | 8 |
| SLA breach rate | ~15% |
| Pipeline runtime (XS WH) | < 10 seconds |
| Monthly Snowflake compute cost | ~$1.35 |
| Monthly Databricks equivalent | ~$216 |
