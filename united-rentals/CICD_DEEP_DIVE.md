# United Rentals — CI/CD Deep Dive

> How the database-as-a-container pattern, environment-scoped RBAC, and GitHub Actions
> combine to replace UR's 3-account architecture with a single-account CI/CD pipeline.

---

## Table of Contents

1. [The Problem](#the-problem)
2. [Architecture Overview](#architecture-overview)
3. [Snowflake-Side Implementation](#snowflake-side-implementation)
4. [GitHub Actions Pipelines](#github-actions-pipelines)
5. [Python Tooling](#python-tooling)
6. [Environment Registry — The Central Contract](#environment-registry--the-central-contract)
7. [Promotion Flow: End to End](#promotion-flow-end-to-end)
8. [Clone Lifecycle: Team Self-Service](#clone-lifecycle-team-self-service)
9. [Security Model: Why This Works](#security-model-why-this-works)
10. [GitHub Secrets & Environment Setup](#github-secrets--environment-setup)
11. [Workshop Demo Script](#workshop-demo-script)

---

## The Problem

United Rentals currently operates **three separate Snowflake accounts**:

| Account | Purpose | Auth | Tooling |
|---------|---------|------|---------|
| EDW Production | Core data warehouse | Local/service accounts | Wherescape Red |
| EDW Development | Mirror of production | Local accounts | Manual SQL |
| Discovery | AI/ML experimentation | SSO + RLS | Cortex AI |

This creates three problems CI/CD must solve:

1. **No promotion path** — Code moves from Dev to Prod via copy/paste or manual execution
2. **No environment isolation guarantee** — A developer with Prod access can accidentally (or intentionally) modify production
3. **No audit trail** — Nobody knows who deployed what, when, or whether it was validated

The single-account architecture with CI/CD RBAC solves all three.

---

## Architecture Overview

### The Core Idea

Replace **account boundaries** with **database boundaries + role-scoped grants**.

```
BEFORE (3 accounts):
  EDW Prod Account  ←→  EDW Dev Account  ←→  Discovery Account
  (account wall)         (account wall)        (account wall)

AFTER (1 account, role walls):
  ┌─ SINGLE ACCOUNT ──────────────────────────────────────────────┐
  │  *_DEV databases     *_STG databases     *_PROD databases     │
  │  UR_CICD_DEPLOY_DEV  UR_CICD_DEPLOY_STG  UR_CICD_DEPLOY_PROD │
  │  (role wall)         (role wall)          (role wall)          │
  └───────────────────────────────────────────────────────────────┘
```

The key guarantee: **deploy roles are siblings, not a hierarchy**. `UR_CICD_DEPLOY_DEV` does NOT inherit from `UR_CICD_DEPLOY_PROD`. A compromised DEV service account cannot touch PROD because there is no grant path.

### Component Map

| Component | Location | Purpose |
|-----------|----------|---------|
| Environment databases | `RAW/CURATED/SEM_{DEV,STG,PROD}` | The "containers" — database boundary = environment boundary |
| CI/CD roles | `07_ur_cicd_environments.sql` §2 | 6 roles with environment-scoped grants |
| Environment Registry | `GOVERNANCE.CONTRACTS.ENVIRONMENT_REGISTRY` | Dynamic target resolution — no hardcoded DB names |
| Promotion procedures | `GOVERNANCE.CONTRACTS.PROMOTE_OBJECT` etc. | Governed object movement between environments |
| Main CI/CD workflow | `.github/workflows/ur-snowflake-cicd.yml` | GitHub Actions: lint → validate → deploy → test |
| Clone workflow | `.github/workflows/ur-clone-lifecycle.yml` | Team clone provisioning + scheduled cleanup |
| Deploy script | `tools/sf_deploy.py` | Registry-driven SQL deployment |
| Validation script | `tools/sf_validate.py` | Promotion gate checks via stored procedures |
| Integration tests | `tools/sf_integration_tests.py` | Post-deploy verification (smoke + full suites) |

See [CICD_RBAC_DIAGRAMS.md](CICD_RBAC_DIAGRAMS.md) for the full set of Mermaid diagrams.

---

## Snowflake-Side Implementation

All Snowflake objects are created by `sql/07_ur_cicd_environments.sql` (944 lines, 7 sections).

### 1. Environment Databases (§1)

Nine databases form the 3×3 grid (3 environments × 3 data layers):

| | DEV | STG | PROD |
|---|---|---|---|
| **RAW** | `RAW_DEV` (existing) | `RAW_STG` | `RAW_PROD` |
| **CURATED** | `CURATED_DEV` (existing) | `CURATED_STG` | `CURATED_PROD` |
| **SEMANTIC** | `SEM_DEV` (existing) | `SEM_STG` | `SEM_PROD` |

Each database contains a `UNITED_RENTALS` schema. The DEV databases already exist from `01_ur_setup.sql`; STG and PROD are created by this script.

### 2. CI/CD Roles (§2)

```
DATA_ADMIN
  ├── UR_PLATFORM_ADMIN              ← Platform team: CI/CD infrastructure
  │     ├── UR_CICD_DEPLOY_PROD      ← Pipeline → PROD databases ONLY
  │     ├── UR_CICD_DEPLOY_STG       ← Pipeline → STG databases ONLY
  │     ├── UR_CICD_DEPLOY_DEV       ← Pipeline → DEV databases ONLY
  │     └── UR_CICD_VALIDATOR        ← Read-only across ALL environments
  └── UR_CLONE_PROVISIONER           ← Creates/drops team dev clones
```

**Critical design**: The three deploy roles are siblings under `UR_PLATFORM_ADMIN`. None inherits from another. This means:
- `UR_CICD_DEPLOY_DEV` has `ALL` on `*_DEV` databases and **nothing** on `*_STG` or `*_PROD`
- `UR_CICD_DEPLOY_PROD` has `ALL` on `*_PROD` databases and **nothing** on `*_DEV` or `*_STG`
- There is no grant path from DEV → PROD

### 3. Environment-Scoped Grants (§3)

Each deploy role gets:
- `USAGE` on its target databases
- `ALL` on all schemas in those databases
- `ALL` on all current and future objects in those schemas

The validator role gets:
- `USAGE` + `SELECT` across all environments (for cross-env validation)
- `SELECT` on governance tables (for promotion log auditing)

### 4. Stored Procedures (§6)

| Procedure | Used By | Purpose |
|-----------|---------|---------|
| `PROVISION_DEV_CLONE` | `UR_CLONE_PROVISIONER` | Creates RAW+CURATED+SEM clone set from PROD with TTL |
| `VALIDATE_PROMOTION` | `UR_CICD_VALIDATOR` | 4 pre-flight checks: role auth, source objects, approval, target resolution |
| `PROMOTE_OBJECT` | Deploy roles | Executes CLONE/SWAP/DDL promotion with audit logging |
| `CLEANUP_EXPIRED_CLONES` | `UR_CLONE_PROVISIONER` | Drops databases past their TTL |

---

## GitHub Actions Pipelines

### Main Pipeline: `ur-snowflake-cicd.yml`

Triggers on changes to `demos/united-rentals/` files:

```
PR to develop          push to develop          push to main
     │                       │                        │
     ▼                       ▼                        ▼
  ┌──────┐               ┌──────┐                ┌──────┐
  │ lint │               │ lint │                │ lint │
  └──┬───┘               └──┬───┘                └──┬───┘
     ▼                       ▼                        ▼
  ┌──────────┐           ┌──────────┐            ┌──────────┐
  │ validate │           │ validate │            │ validate │
  └──┬───────┘           └──┬───────┘            └──┬───────┘
     ▼                       ▼                        ▼
  ┌────────────┐         ┌────────────┐          ┌────────────────────┐
  │ deploy-dev │         │ deploy-stg │          │ deploy-prod        │
  │ DEPLOY_DEV │         │ DEPLOY_STG │          │ DEPLOY_PROD        │
  │ + smoke    │         │ + full     │          │ GitHub Env approval│
  │   tests    │         │   tests    │          │ + strict validate  │
  └────────────┘         └────────────┘          │ + full tests       │
                                                 │ + audit log        │
                                                 └────────────────────┘
```

**Job details:**

| Job | Trigger | Snowflake Role | What It Does |
|-----|---------|----------------|--------------|
| `lint` | All | None (offline) | sqlfluff lint with Snowflake dialect |
| `validate` | All | `UR_CICD_VALIDATOR` | Calls `sf_validate.py` → `VALIDATE_PROMOTION` |
| `deploy-dev` | PR to develop | `UR_CICD_DEPLOY_DEV` | Deploy SQL, smoke test |
| `deploy-stg` | Push to develop | `UR_CICD_DEPLOY_STG` | Deploy SQL, full integration test |
| `deploy-prod` | Push to main | `UR_CICD_DEPLOY_PROD` | Strict validate, deploy, full test, audit log |

**PROD has two layers of approval:**
1. **GitHub Environment protection** — Required reviewers before the job runs
2. **Snowflake ENVIRONMENT_REGISTRY** — `REQUIRES_APPROVAL = TRUE` for PROD rows

### Clone Lifecycle: `ur-clone-lifecycle.yml`

Three actions via `workflow_dispatch`:

| Action | Input | What It Does |
|--------|-------|--------------|
| `provision` | team_name, team_role, ttl_days | Calls `PROVISION_DEV_CLONE`, reports clone status |
| `cleanup` | — | Calls `CLEANUP_EXPIRED_CLONES` |
| `status` | — | Queries `VW_ACTIVE_CLONES`, prints summary |

Also runs cleanup on a **daily schedule** at 6 AM CT (11:00 UTC).

---

## Python Tooling

All three scripts follow the same pattern:
1. Connect to Snowflake using environment variables (key-pair auth)
2. Query `ENVIRONMENT_REGISTRY` for dynamic target resolution
3. Execute the action using the Snowflake role set via `SNOWFLAKE_ROLE`
4. Exit with code 0 (success) or 1 (failure) for GitHub Actions

### `sf_deploy.py` — Registry-Driven Deployment

The deploy script **never hardcodes database names**. It resolves targets at runtime:

```python
# Instead of:
cursor.execute("CREATE TABLE CURATED_PROD.UNITED_RENTALS.DIM_BRANCH ...")  # BAD

# It does:
target = resolve_target(conn, "PROD", "CURATED")
# target = {"database": "CURATED_PROD", "deploy_role": "UR_CICD_DEPLOY_PROD", ...}
cursor.execute(f"USE DATABASE {target['database']}")
cursor.execute("CREATE TABLE UNITED_RENTALS.DIM_BRANCH ...")  # GOOD
```

This means if UR renames databases or adds environments, only the registry changes — not the pipeline.

**Actions:**
- `resolve` — Print resolved targets (dry run)
- `deploy` — Execute SQL files against resolved databases
- `log-promotion` — Write to `PROMOTION_LOG`
- `promote-object` — Call `PROMOTE_OBJECT` stored procedure

### `sf_validate.py` — Promotion Gates

Calls `VALIDATE_PROMOTION` for each data layer. Checks:

| Gate | Severity | What It Checks |
|------|----------|----------------|
| `ROLE_AUTHORIZATION` | ERROR | Is the current role authorized for the target env? |
| `SOURCE_HAS_OBJECTS` | ERROR | Does the source schema have objects to promote? |
| `APPROVAL_REQUIRED` | WARNING | Does the target require human approval? |
| `TARGET_RESOLVED` | ERROR | Can the registry resolve a target database? |
| `REGISTRY_COMPLETENESS` | ERROR | Are all 3 layers registered? (meta-check) |
| `ROW_COUNT_*` | WARNING | Cross-env row count drift detection |

In `--strict` mode (used for PROD), WARNING-severity issues also block.

### `sf_integration_tests.py` — Post-Deploy Verification

**Smoke suite** (fast, ~30s):
- Schema exists in each resolved database
- Key tables have rows (branches, equipment, etc.)
- Governance tables accessible

**Full suite** (comprehensive):
- Everything in smoke, plus:
- Write rejection test (proves `UR_CICD_VALIDATOR` is truly read-only)
- Environment registry entry validation
- CI/CD views queryable
- Cross-env data consistency (row count drift)
- Governance tags present on key tables

---

## Environment Registry — The Central Contract

The `ENVIRONMENT_REGISTRY` table is the **single source of truth** for the CI/CD pipeline. Every tool queries it. Nothing is hardcoded.

```sql
SELECT * FROM GOVERNANCE.CONTRACTS.ENVIRONMENT_REGISTRY;
```

| ENVIRONMENT | LAYER | DATABASE_NAME | DEPLOY_ROLE | REQUIRES_APPROVAL | APPROVAL_ROLE |
|-------------|-------|---------------|-------------|:-:|---|
| DEV | RAW | RAW_DEV | UR_CICD_DEPLOY_DEV | FALSE | — |
| DEV | CURATED | CURATED_DEV | UR_CICD_DEPLOY_DEV | FALSE | — |
| DEV | SEMANTIC | SEM_DEV | UR_CICD_DEPLOY_DEV | FALSE | — |
| STG | RAW | RAW_STG | UR_CICD_DEPLOY_STG | FALSE | — |
| STG | CURATED | CURATED_STG | UR_CICD_DEPLOY_STG | FALSE | — |
| STG | SEMANTIC | SEM_STG | UR_CICD_DEPLOY_STG | FALSE | — |
| PROD | RAW | RAW_PROD | UR_CICD_DEPLOY_PROD | TRUE | UR_PLATFORM_ADMIN |
| PROD | CURATED | CURATED_PROD | UR_CICD_DEPLOY_PROD | TRUE | UR_PLATFORM_ADMIN |
| PROD | SEMANTIC | SEM_PROD | UR_CICD_DEPLOY_PROD | TRUE | UR_PLATFORM_ADMIN |

**Why this matters:**
- Adding a new environment (e.g., `QA`) = INSERT 3 rows + create databases + create role
- Renaming a database = UPDATE the registry, nothing else changes
- The pipeline YAML never changes for environment additions

---

## Promotion Flow: End to End

### Scenario: Engineer adds a new dimension table

```
1. Engineer creates feature branch, adds DIM_FLEET_CATEGORY to curated layer SQL
2. Opens PR to `develop`

   ┌─ GitHub Actions: ur-snowflake-cicd.yml ─────────────────────────────┐
   │                                                                      │
   │  [lint] sqlfluff checks SQL syntax                                   │
   │    ↓                                                                 │
   │  [validate] sf_validate.py --target-env DEV                          │
   │    → CALL VALIDATE_PROMOTION('CURATED_DEV', 'DEV', 'UNITED_RENTALS')│
   │    → Checks: role auth ✓, source objects ✓, target resolved ✓       │
   │    ↓                                                                 │
   │  [deploy-dev] sf_deploy.py --action deploy --target-env DEV          │
   │    → Resolves: CURATED → CURATED_DEV (from ENVIRONMENT_REGISTRY)    │
   │    → Executes SQL as UR_CICD_DEPLOY_DEV                             │
   │    ↓                                                                 │
   │  [smoke-test] sf_integration_tests.py --target-env DEV --suite smoke │
   │    → Schema exists ✓, DIM_FLEET_CATEGORY has rows ✓                 │
   │                                                                      │
   └──────────────────────────────────────────────────────────────────────┘

3. PR approved, merged to `develop`

   ┌─ GitHub Actions (push to develop) ──────────────────────────────────┐
   │  [validate] sf_validate.py --target-env STG                         │
   │  [deploy-stg] sf_deploy.py --action deploy --target-env STG         │
   │    → Resolves: CURATED → CURATED_STG                                │
   │    → Executes SQL as UR_CICD_DEPLOY_STG                             │
   │  [full-test] sf_integration_tests.py --target-env STG --suite full  │
   │    → Cross-env row count consistency ✓, write blocked ✓             │
   └─────────────────────────────────────────────────────────────────────┘

4. Release PR from `develop` → `main`, approved by platform team

   ┌─ GitHub Actions (push to main) ─────────────────────────────────────┐
   │  GitHub Environment "production" → required reviewer approves       │
   │  [validate] sf_validate.py --target-env PROD --strict               │
   │  [deploy-prod] sf_deploy.py --action deploy --target-env PROD       │
   │    → Resolves: CURATED → CURATED_PROD                               │
   │    → Executes SQL as UR_CICD_DEPLOY_PROD                            │
   │  [full-test] sf_integration_tests.py --target-env PROD --suite full │
   │  [audit] sf_deploy.py --action log-promotion --status SUCCESS       │
   │    → INSERT INTO PROMOTION_LOG (sha, branch, status, ...)           │
   └─────────────────────────────────────────────────────────────────────┘
```

### Promotion Methods (via `PROMOTE_OBJECT`)

| Method | Use Case | Mechanism |
|--------|----------|-----------|
| **CLONE** | Tables with data | `CREATE OR REPLACE TABLE target CLONE source` — instant, zero-copy |
| **SWAP** | Hot-swap with rollback | `ALTER TABLE target SWAP WITH source` — atomic, instant rollback |
| **DDL** | Views, procedures, UDFs | Pipeline executes `CREATE OR REPLACE` directly from Git |

---

## Clone Lifecycle: Team Self-Service

### How Teams Get Dev Environments

```
1. Manning team requests a clone:
   → GitHub Actions: ur-clone-lifecycle.yml (workflow_dispatch)
   → Inputs: team_name=MANNING, team_role=MANNING_TEAM_ROLE, ttl_days=14

2. Provisioner creates 3 zero-copy clones:
   → RAW_MANNING_DEV     (clone of RAW_PROD)
   → CURATED_MANNING_DEV (clone of CURATED_PROD)
   → SEM_MANNING_DEV     (clone of SEM_PROD)

3. Grants applied:
   → MANNING_TEAM_ROLE gets ALL on all 3 databases
   → UR_CICD_DEPLOY_DEV gets ALL (so pipelines work in the clone)

4. Clone registered in CLONE_REGISTRY with TTL=14 days

5. Daily at 6 AM CT: CLEANUP_EXPIRED_CLONES drops anything past TTL
```

This replaces UR's current process of manually requesting a Dev account copy — which takes days and produces a full (expensive) duplicate.

---

## Security Model: Why This Works

### The Grant IS the Wall

In a multi-account setup, isolation comes from account boundaries. In single-account, it comes from **the absence of grants**:

```sql
-- UR_CICD_DEPLOY_DEV has:
GRANT ALL ON DATABASE RAW_DEV TO ROLE UR_CICD_DEPLOY_DEV;       -- ✓
GRANT ALL ON DATABASE CURATED_DEV TO ROLE UR_CICD_DEPLOY_DEV;   -- ✓
GRANT ALL ON DATABASE SEM_DEV TO ROLE UR_CICD_DEPLOY_DEV;       -- ✓

-- UR_CICD_DEPLOY_DEV does NOT have:
-- (no grants to RAW_STG, CURATED_STG, SEM_STG)                  -- ✗
-- (no grants to RAW_PROD, CURATED_PROD, SEM_PROD)               -- ✗
```

There is no `DENY` — the security model is **default deny, explicit allow**.

### Why Siblings > Hierarchy

If deploy roles were hierarchical (`DEV → STG → PROD`), compromising `PROD` means you also get `STG` and `DEV`. That's unnecessary risk.

By making them siblings under `UR_PLATFORM_ADMIN`:
- Compromised `UR_CICD_DEPLOY_DEV` → can touch DEV **only**
- Compromised `UR_CICD_DEPLOY_PROD` → can touch PROD **only**
- Only `UR_PLATFORM_ADMIN` (platform team) has cross-environment access

### Defense in Depth

| Layer | Mechanism | What It Prevents |
|-------|-----------|-----------------|
| 1. GitHub branch protection | Required reviewers on `main` | Unauthorized code reaching PROD pipeline |
| 2. GitHub Environment protection | Required approvers for `production` | Pipeline running without human approval |
| 3. Snowflake role scoping | No cross-env grants on deploy roles | Service account accessing wrong environment |
| 4. `VALIDATE_PROMOTION` procedure | Role authorization check | Wrong role attempting deployment |
| 5. `ENVIRONMENT_REGISTRY` | `REQUIRES_APPROVAL = TRUE` for PROD | Pipeline skipping approval step |
| 6. `PROMOTION_LOG` | Immutable audit trail | Untracked deployments |
| 7. Integration tests | Write-rejection test | Validator role accidentally gaining write access |

---

## GitHub Secrets & Environment Setup

### Required Repository Secrets

| Secret | Value | Used By |
|--------|-------|---------|
| `SNOWFLAKE_ACCOUNT` | Snowflake account identifier | All jobs |
| `SNOWFLAKE_PRIVATE_KEY` | RSA private key (PEM) for key-pair auth | All jobs |
| `SNOWFLAKE_USER_DEV` | Service account for DEV deployments | `deploy-dev` |
| `SNOWFLAKE_USER_STG` | Service account for STG deployments | `deploy-stg` |
| `SNOWFLAKE_USER_PROD` | Service account for PROD deployments | `deploy-prod` |
| `SNOWFLAKE_USER_VALIDATOR` | Service account for validation/testing | `validate`, tests |
| `SNOWFLAKE_USER_CLONE` | Service account for clone operations | Clone lifecycle |

### GitHub Environments

Create two environments in GitHub repo settings:

**`staging`**
- No required reviewers (automated promotion)
- Deployment branch: `develop`

**`production`**
- Required reviewers: platform team members
- Deployment branch: `main`
- Wait timer: optional (e.g., 5 minutes for rollback window)

### Snowflake Service Account Setup

Each GitHub secret corresponds to a Snowflake user with key-pair auth:

```sql
-- Create service accounts (run as ACCOUNTADMIN)
CREATE USER IF NOT EXISTS SVC_CICD_DEV
    RSA_PUBLIC_KEY = '<public_key>'
    DEFAULT_ROLE = UR_CICD_DEPLOY_DEV
    DEFAULT_WAREHOUSE = TRANSFORM_WH;

CREATE USER IF NOT EXISTS SVC_CICD_STG
    RSA_PUBLIC_KEY = '<public_key>'
    DEFAULT_ROLE = UR_CICD_DEPLOY_STG
    DEFAULT_WAREHOUSE = TRANSFORM_WH;

CREATE USER IF NOT EXISTS SVC_CICD_PROD
    RSA_PUBLIC_KEY = '<public_key>'
    DEFAULT_ROLE = UR_CICD_DEPLOY_PROD
    DEFAULT_WAREHOUSE = TRANSFORM_WH;

CREATE USER IF NOT EXISTS SVC_CICD_VALIDATOR
    RSA_PUBLIC_KEY = '<public_key>'
    DEFAULT_ROLE = UR_CICD_VALIDATOR
    DEFAULT_WAREHOUSE = TRANSFORM_WH;

CREATE USER IF NOT EXISTS SVC_CLONE_PROVISIONER
    RSA_PUBLIC_KEY = '<public_key>'
    DEFAULT_ROLE = UR_CLONE_PROVISIONER
    DEFAULT_WAREHOUSE = TRANSFORM_WH;

-- Grant roles to service accounts
GRANT ROLE UR_CICD_DEPLOY_DEV TO USER SVC_CICD_DEV;
GRANT ROLE UR_CICD_DEPLOY_STG TO USER SVC_CICD_STG;
GRANT ROLE UR_CICD_DEPLOY_PROD TO USER SVC_CICD_PROD;
GRANT ROLE UR_CICD_VALIDATOR TO USER SVC_CICD_VALIDATOR;
GRANT ROLE UR_CLONE_PROVISIONER TO USER SVC_CLONE_PROVISIONER;
```

---

## Workshop Demo Script

### 1. Prove Environment Isolation (2 min)

```sql
-- Switch to DEV deployer — show it can write to DEV
USE ROLE UR_CICD_DEPLOY_DEV;
SHOW SCHEMAS IN DATABASE RAW_DEV;       -- ✓ Works
SHOW SCHEMAS IN DATABASE RAW_PROD;      -- ✗ Access denied

-- Switch to PROD deployer — show it can write to PROD but not DEV
USE ROLE UR_CICD_DEPLOY_PROD;
SHOW SCHEMAS IN DATABASE RAW_PROD;      -- ✓ Works
SHOW SCHEMAS IN DATABASE RAW_DEV;       -- ✗ Access denied

-- Validator can read everything but write nothing
USE ROLE UR_CICD_VALIDATOR;
SELECT COUNT(*) FROM CURATED_DEV.UNITED_RENTALS.DIM_BRANCH;   -- ✓ Read
SELECT COUNT(*) FROM CURATED_PROD.UNITED_RENTALS.DIM_BRANCH;  -- ✓ Read
CREATE TABLE CURATED_PROD.UNITED_RENTALS.TEST (ID INT);        -- ✗ Denied
```

### 2. Show the Environment Registry (1 min)

```sql
USE ROLE UR_CICD_VALIDATOR;
SELECT ENVIRONMENT, LAYER, DATABASE_NAME, DEPLOY_ROLE, REQUIRES_APPROVAL
FROM GOVERNANCE.CONTRACTS.ENVIRONMENT_REGISTRY
ORDER BY ENVIRONMENT, LAYER;
```

### 3. Walk Through the GitHub Actions Workflow (3 min)

Open `.github/workflows/ur-snowflake-cicd.yml` and trace:
- Each job maps to a Snowflake role
- The `validate` job uses `UR_CICD_VALIDATOR` (read-only)
- The `deploy-*` jobs each use their environment's deploy role
- PROD requires GitHub Environment approval

### 4. Show the Role Matrix View (1 min)

```sql
SELECT * FROM GOVERNANCE.CONTRACTS.VW_CICD_ROLE_MATRIX
ORDER BY ROLE_TYPE, ROLE_NAME;
```

### 5. Demo Clone Provisioning (2 min)

```sql
-- Provision a clone set for Manning team
USE ROLE UR_CLONE_PROVISIONER;
CALL GOVERNANCE.CONTRACTS.PROVISION_DEV_CLONE('MANNING', 'UR_FLEET_MANAGER', 14);

-- Show active clones
USE ROLE UR_CICD_VALIDATOR;
SELECT * FROM GOVERNANCE.CONTRACTS.VW_ACTIVE_CLONES;
```

### 6. Show Promotion Audit Trail (1 min)

```sql
SELECT * FROM GOVERNANCE.CONTRACTS.VW_PROMOTION_HISTORY;
```
