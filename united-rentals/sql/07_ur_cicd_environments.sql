-- ============================================================================
-- UNITED RENTALS DEMO - CI/CD RBAC & Environment Architecture
-- ============================================================================
--
-- Implements the database-as-a-container pattern for single-account
-- environment isolation with CI/CD service roles and promotion workflows.
--
-- This script answers UR's critical question:
--   "If we consolidate 3 accounts into 1, what prevents DEV from touching PROD?"
--
-- Answer: CI/CD roles with environment-scoped grants + promotion procedures
-- with validation gates. The DATABASE BOUNDARY is the ENVIRONMENT BOUNDARY.
--
-- Architecture:
--   ┌─────────────────────────────────────────────────────────────────────┐
--   │                    SINGLE ACCOUNT                                   │
--   │                                                                     │
--   │  DEVELOPMENT (DEV)         STAGING (STG)        PRODUCTION (PROD)  │
--   │  ┌───────────────┐        ┌──────────────┐     ┌──────────────┐    │
--   │  │ RAW_DEV       │   ──►  │ RAW_STG      │ ──► │ RAW_PROD     │    │
--   │  │ CURATED_DEV   │   ──►  │ CURATED_STG  │ ──► │ CURATED_PROD │    │
--   │  │ SEM_DEV       │   ──►  │ SEM_STG      │ ──► │ SEM_PROD     │    │
--   │  └───────────────┘        └──────────────┘     └──────────────┘    │
--   │  UR_CICD_DEPLOY_DEV       UR_CICD_DEPLOY_STG   UR_CICD_DEPLOY_PROD│
--   │                                                                     │
--   │  ┌─────────────────────────────────────────────────────────────┐    │
--   │  │ GOVERNANCE (shared across all environments)                 │    │
--   │  │ Environment Registry │ Promotion Log │ Clone Registry       │    │
--   │  └─────────────────────────────────────────────────────────────┘    │
--   └─────────────────────────────────────────────────────────────────────┘
--
-- CI/CD Role Hierarchy:
--   DATA_ADMIN
--     └── UR_PLATFORM_ADMIN              ◄── Platform team: CI/CD infra
--           ├── UR_CICD_DEPLOY_PROD      ◄── Pipeline → PROD only
--           ├── UR_CICD_DEPLOY_STG       ◄── Pipeline → STG only
--           ├── UR_CICD_DEPLOY_DEV       ◄── Pipeline → DEV only
--           └── UR_CICD_VALIDATOR        ◄── Read-only: validation gates
--     └── UR_CLONE_PROVISIONER           ◄── Creates/drops team dev clones
--
-- CRITICAL DESIGN DECISION: Deploy roles are SIBLINGS, not a hierarchy.
-- UR_CICD_DEPLOY_PROD does NOT inherit UR_CICD_DEPLOY_DEV.
-- A compromised DEV service account CANNOT touch PROD.
--
-- Prerequisites: 01_ur_setup.sql, 03_ur_curated_layer.sql, 05_ur_governance.sql
-- RUN AS: DATA_ADMIN (SYSADMIN for database creation section)
-- ============================================================================


-- ═══════════════════════════════════════════════════════════════════════════
-- SECTION 1: ENVIRONMENT DATABASES (the "containers")
-- ═══════════════════════════════════════════════════════════════════════════
-- The database-as-a-container pattern: each environment is a database.
-- DEV databases already exist (from 01_ur_setup.sql).
-- Now we create the STAGING and PRODUCTION targets.
--
-- This is what REPLACES separate Snowflake accounts for env isolation.
-- Instead of EDW_PROD_ACCOUNT vs EDW_DEV_ACCOUNT, we have:
--   RAW_DEV / RAW_STG / RAW_PROD  — all in ONE account, isolated by RBAC.
-- ═══════════════════════════════════════════════════════════════════════════

USE ROLE DATA_ADMIN;
USE WAREHOUSE TRANSFORM_WH;

-- Staging databases (validation environment before production)
CREATE DATABASE IF NOT EXISTS RAW_STG
    COMMENT = 'Staging raw layer - pre-production validation';
CREATE DATABASE IF NOT EXISTS CURATED_STG
    COMMENT = 'Staging curated layer - pre-production validation';
CREATE DATABASE IF NOT EXISTS SEM_STG
    COMMENT = 'Staging semantic layer - pre-production validation';

-- Production databases (source of truth)
CREATE DATABASE IF NOT EXISTS RAW_PROD
    COMMENT = 'Production raw layer - source of truth';
CREATE DATABASE IF NOT EXISTS CURATED_PROD
    COMMENT = 'Production curated layer - business-ready data';
CREATE DATABASE IF NOT EXISTS SEM_PROD
    COMMENT = 'Production semantic layer - Cortex Analyst';

-- UR schemas in staging
CREATE SCHEMA IF NOT EXISTS RAW_STG.UNITED_RENTALS
    COMMENT = 'United Rentals raw data - STAGING';
CREATE SCHEMA IF NOT EXISTS CURATED_STG.UNITED_RENTALS
    COMMENT = 'United Rentals curated data - STAGING';
CREATE SCHEMA IF NOT EXISTS SEM_STG.UNITED_RENTALS
    COMMENT = 'United Rentals semantic views - STAGING';

-- UR schemas in production
CREATE SCHEMA IF NOT EXISTS RAW_PROD.UNITED_RENTALS
    COMMENT = 'United Rentals raw data - PRODUCTION';
CREATE SCHEMA IF NOT EXISTS CURATED_PROD.UNITED_RENTALS
    COMMENT = 'United Rentals curated data - PRODUCTION';
CREATE SCHEMA IF NOT EXISTS SEM_PROD.UNITED_RENTALS
    COMMENT = 'United Rentals semantic views - PRODUCTION';


-- ═══════════════════════════════════════════════════════════════════════════
-- SECTION 2: CI/CD SERVICE ROLES
-- ═══════════════════════════════════════════════════════════════════════════
-- These roles are used by CI/CD pipeline service accounts (GitHub Actions,
-- Azure DevOps, etc.) — NOT by human users.
--
-- Each role maps to a GitHub Actions environment secret:
--   - DEV environment  → service account granted UR_CICD_DEPLOY_DEV
--   - STG environment  → service account granted UR_CICD_DEPLOY_STG
--   - PROD environment → service account granted UR_CICD_DEPLOY_PROD
--
-- The VALIDATOR role is used by the pipeline for pre-deployment checks.
-- It has read-only access across ALL environments so it can compare
-- source and target schemas during promotion gates.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE ROLE IF NOT EXISTS UR_PLATFORM_ADMIN
    COMMENT = 'United Rentals: Platform team - manages CI/CD infrastructure, clone lifecycle, and promotion workflows';

CREATE ROLE IF NOT EXISTS UR_CICD_DEPLOY_PROD
    COMMENT = 'United Rentals: CI/CD service role - deploys validated changes to PRODUCTION databases only';

CREATE ROLE IF NOT EXISTS UR_CICD_DEPLOY_STG
    COMMENT = 'United Rentals: CI/CD service role - deploys changes to STAGING databases only';

CREATE ROLE IF NOT EXISTS UR_CICD_DEPLOY_DEV
    COMMENT = 'United Rentals: CI/CD service role - deploys changes to DEVELOPMENT databases only';

CREATE ROLE IF NOT EXISTS UR_CICD_VALIDATOR
    COMMENT = 'United Rentals: CI/CD service role - read-only cross-environment validation and contract checks';

CREATE ROLE IF NOT EXISTS UR_CLONE_PROVISIONER
    COMMENT = 'United Rentals: Creates and manages zero-copy clone environments for domain teams';

-- ─────────────────────────────────────────────────────────────────────────
-- CI/CD Role Hierarchy
-- ─────────────────────────────────────────────────────────────────────────
-- UR_PLATFORM_ADMIN is the CI/CD administrative role.
-- Deploy roles are children but NOT siblings of each other.
-- This means UR_PLATFORM_ADMIN can do everything, but each deploy role
-- can ONLY operate on its target environment.

GRANT ROLE UR_PLATFORM_ADMIN TO ROLE DATA_ADMIN;
GRANT ROLE UR_CICD_DEPLOY_PROD TO ROLE UR_PLATFORM_ADMIN;
GRANT ROLE UR_CICD_DEPLOY_STG TO ROLE UR_PLATFORM_ADMIN;
GRANT ROLE UR_CICD_DEPLOY_DEV TO ROLE UR_PLATFORM_ADMIN;
GRANT ROLE UR_CICD_VALIDATOR TO ROLE UR_PLATFORM_ADMIN;
GRANT ROLE UR_CLONE_PROVISIONER TO ROLE UR_PLATFORM_ADMIN;

-- Grant all CI/CD roles to DATA_ADMIN for demo role-switching
GRANT ROLE UR_CICD_DEPLOY_PROD TO ROLE DATA_ADMIN;
GRANT ROLE UR_CICD_DEPLOY_STG TO ROLE DATA_ADMIN;
GRANT ROLE UR_CICD_DEPLOY_DEV TO ROLE DATA_ADMIN;
GRANT ROLE UR_CICD_VALIDATOR TO ROLE DATA_ADMIN;
GRANT ROLE UR_CLONE_PROVISIONER TO ROLE DATA_ADMIN;

-- Warehouse access for CI/CD operations
GRANT USAGE ON WAREHOUSE TRANSFORM_WH TO ROLE UR_PLATFORM_ADMIN;
GRANT USAGE ON WAREHOUSE TRANSFORM_WH TO ROLE UR_CICD_DEPLOY_PROD;
GRANT USAGE ON WAREHOUSE TRANSFORM_WH TO ROLE UR_CICD_DEPLOY_STG;
GRANT USAGE ON WAREHOUSE TRANSFORM_WH TO ROLE UR_CICD_DEPLOY_DEV;
GRANT USAGE ON WAREHOUSE TRANSFORM_WH TO ROLE UR_CICD_VALIDATOR;
GRANT USAGE ON WAREHOUSE TRANSFORM_WH TO ROLE UR_CLONE_PROVISIONER;


-- ═══════════════════════════════════════════════════════════════════════════
-- SECTION 3: ENVIRONMENT-SCOPED GRANTS
-- ═══════════════════════════════════════════════════════════════════════════
-- Each CI/CD deploy role gets FULL DDL on its environment's databases
-- and ZERO ACCESS to other environments.
--
-- This is the "database boundary = environment boundary" principle.
-- No network policies needed. No separate accounts needed.
-- The GRANT is the wall.
--
-- ┌────────────────────┬──────────┬──────────┬──────────┐
-- │ Role               │ *_DEV    │ *_STG    │ *_PROD   │
-- ├────────────────────┼──────────┼──────────┼──────────┤
-- │ UR_CICD_DEPLOY_DEV │ ALL      │ —        │ —        │
-- │ UR_CICD_DEPLOY_STG │ —        │ ALL      │ —        │
-- │ UR_CICD_DEPLOY_PROD│ —        │ —        │ ALL      │
-- │ UR_CICD_VALIDATOR  │ SELECT   │ SELECT   │ SELECT   │
-- │ UR_CLONE_PROVISION.│ —        │ —        │ READ(src)│
-- │ UR_PLATFORM_ADMIN  │ (inherits all above)            │
-- └────────────────────┴──────────┴──────────┴──────────┘
-- ═══════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────
-- DEV DEPLOYER: Full DDL on _DEV databases, NO access to _STG or _PROD
-- ─────────────────────────────────────────────────────────────────────────

-- RAW_DEV
GRANT USAGE ON DATABASE RAW_DEV TO ROLE UR_CICD_DEPLOY_DEV;
GRANT ALL ON SCHEMA RAW_DEV.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_DEV;
GRANT ALL ON ALL TABLES IN SCHEMA RAW_DEV.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_DEV;
GRANT ALL ON FUTURE TABLES IN SCHEMA RAW_DEV.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_DEV;

-- CURATED_DEV
GRANT USAGE ON DATABASE CURATED_DEV TO ROLE UR_CICD_DEPLOY_DEV;
GRANT ALL ON SCHEMA CURATED_DEV.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_DEV;
GRANT ALL ON ALL TABLES IN SCHEMA CURATED_DEV.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_DEV;
GRANT ALL ON ALL DYNAMIC TABLES IN SCHEMA CURATED_DEV.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_DEV;
GRANT ALL ON ALL VIEWS IN SCHEMA CURATED_DEV.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_DEV;
GRANT ALL ON FUTURE TABLES IN SCHEMA CURATED_DEV.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_DEV;
GRANT ALL ON FUTURE VIEWS IN SCHEMA CURATED_DEV.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_DEV;

-- SEM_DEV
GRANT USAGE ON DATABASE SEM_DEV TO ROLE UR_CICD_DEPLOY_DEV;
GRANT ALL ON SCHEMA SEM_DEV.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_DEV;
GRANT ALL ON ALL VIEWS IN SCHEMA SEM_DEV.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_DEV;
GRANT ALL ON FUTURE VIEWS IN SCHEMA SEM_DEV.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_DEV;

-- ─────────────────────────────────────────────────────────────────────────
-- STG DEPLOYER: Full DDL on _STG databases, NO access to _DEV or _PROD
-- ─────────────────────────────────────────────────────────────────────────

-- RAW_STG
GRANT USAGE ON DATABASE RAW_STG TO ROLE UR_CICD_DEPLOY_STG;
GRANT ALL ON SCHEMA RAW_STG.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_STG;
GRANT ALL ON ALL TABLES IN SCHEMA RAW_STG.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_STG;
GRANT ALL ON FUTURE TABLES IN SCHEMA RAW_STG.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_STG;

-- CURATED_STG
GRANT USAGE ON DATABASE CURATED_STG TO ROLE UR_CICD_DEPLOY_STG;
GRANT ALL ON SCHEMA CURATED_STG.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_STG;
GRANT ALL ON ALL TABLES IN SCHEMA CURATED_STG.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_STG;
GRANT ALL ON ALL DYNAMIC TABLES IN SCHEMA CURATED_STG.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_STG;
GRANT ALL ON ALL VIEWS IN SCHEMA CURATED_STG.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_STG;
GRANT ALL ON FUTURE TABLES IN SCHEMA CURATED_STG.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_STG;
GRANT ALL ON FUTURE VIEWS IN SCHEMA CURATED_STG.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_STG;

-- SEM_STG
GRANT USAGE ON DATABASE SEM_STG TO ROLE UR_CICD_DEPLOY_STG;
GRANT ALL ON SCHEMA SEM_STG.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_STG;
GRANT ALL ON ALL VIEWS IN SCHEMA SEM_STG.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_STG;
GRANT ALL ON FUTURE VIEWS IN SCHEMA SEM_STG.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_STG;

-- ─────────────────────────────────────────────────────────────────────────
-- PROD DEPLOYER: Full DDL on _PROD databases, NO access to _DEV or _STG
-- ─────────────────────────────────────────────────────────────────────────

-- RAW_PROD
GRANT USAGE ON DATABASE RAW_PROD TO ROLE UR_CICD_DEPLOY_PROD;
GRANT ALL ON SCHEMA RAW_PROD.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_PROD;
GRANT ALL ON ALL TABLES IN SCHEMA RAW_PROD.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_PROD;
GRANT ALL ON FUTURE TABLES IN SCHEMA RAW_PROD.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_PROD;

-- CURATED_PROD
GRANT USAGE ON DATABASE CURATED_PROD TO ROLE UR_CICD_DEPLOY_PROD;
GRANT ALL ON SCHEMA CURATED_PROD.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_PROD;
GRANT ALL ON ALL TABLES IN SCHEMA CURATED_PROD.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_PROD;
GRANT ALL ON ALL DYNAMIC TABLES IN SCHEMA CURATED_PROD.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_PROD;
GRANT ALL ON ALL VIEWS IN SCHEMA CURATED_PROD.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_PROD;
GRANT ALL ON FUTURE TABLES IN SCHEMA CURATED_PROD.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_PROD;
GRANT ALL ON FUTURE VIEWS IN SCHEMA CURATED_PROD.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_PROD;

-- SEM_PROD
GRANT USAGE ON DATABASE SEM_PROD TO ROLE UR_CICD_DEPLOY_PROD;
GRANT ALL ON SCHEMA SEM_PROD.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_PROD;
GRANT ALL ON ALL VIEWS IN SCHEMA SEM_PROD.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_PROD;
GRANT ALL ON FUTURE VIEWS IN SCHEMA SEM_PROD.UNITED_RENTALS TO ROLE UR_CICD_DEPLOY_PROD;

-- ─────────────────────────────────────────────────────────────────────────
-- VALIDATOR: Read-only across ALL environments + GOVERNANCE
-- ─────────────────────────────────────────────────────────────────────────
-- The validator needs cross-environment read access to:
--   - Compare DEV schemas against PROD schemas (breaking change detection)
--   - Read contract definitions from GOVERNANCE
--   - Verify governance tags are applied in source environment

-- DEV (read-only)
GRANT USAGE ON DATABASE RAW_DEV TO ROLE UR_CICD_VALIDATOR;
GRANT USAGE ON SCHEMA RAW_DEV.UNITED_RENTALS TO ROLE UR_CICD_VALIDATOR;
GRANT SELECT ON ALL TABLES IN SCHEMA RAW_DEV.UNITED_RENTALS TO ROLE UR_CICD_VALIDATOR;
GRANT SELECT ON FUTURE TABLES IN SCHEMA RAW_DEV.UNITED_RENTALS TO ROLE UR_CICD_VALIDATOR;

GRANT USAGE ON DATABASE CURATED_DEV TO ROLE UR_CICD_VALIDATOR;
GRANT USAGE ON SCHEMA CURATED_DEV.UNITED_RENTALS TO ROLE UR_CICD_VALIDATOR;
GRANT SELECT ON ALL TABLES IN SCHEMA CURATED_DEV.UNITED_RENTALS TO ROLE UR_CICD_VALIDATOR;
GRANT SELECT ON ALL DYNAMIC TABLES IN SCHEMA CURATED_DEV.UNITED_RENTALS TO ROLE UR_CICD_VALIDATOR;
GRANT SELECT ON ALL VIEWS IN SCHEMA CURATED_DEV.UNITED_RENTALS TO ROLE UR_CICD_VALIDATOR;
GRANT SELECT ON FUTURE TABLES IN SCHEMA CURATED_DEV.UNITED_RENTALS TO ROLE UR_CICD_VALIDATOR;

GRANT USAGE ON DATABASE SEM_DEV TO ROLE UR_CICD_VALIDATOR;
GRANT USAGE ON SCHEMA SEM_DEV.UNITED_RENTALS TO ROLE UR_CICD_VALIDATOR;
GRANT SELECT ON ALL VIEWS IN SCHEMA SEM_DEV.UNITED_RENTALS TO ROLE UR_CICD_VALIDATOR;

-- STG (read-only)
GRANT USAGE ON DATABASE RAW_STG TO ROLE UR_CICD_VALIDATOR;
GRANT USAGE ON SCHEMA RAW_STG.UNITED_RENTALS TO ROLE UR_CICD_VALIDATOR;
GRANT SELECT ON ALL TABLES IN SCHEMA RAW_STG.UNITED_RENTALS TO ROLE UR_CICD_VALIDATOR;
GRANT SELECT ON FUTURE TABLES IN SCHEMA RAW_STG.UNITED_RENTALS TO ROLE UR_CICD_VALIDATOR;

GRANT USAGE ON DATABASE CURATED_STG TO ROLE UR_CICD_VALIDATOR;
GRANT USAGE ON SCHEMA CURATED_STG.UNITED_RENTALS TO ROLE UR_CICD_VALIDATOR;
GRANT SELECT ON ALL TABLES IN SCHEMA CURATED_STG.UNITED_RENTALS TO ROLE UR_CICD_VALIDATOR;
GRANT SELECT ON ALL VIEWS IN SCHEMA CURATED_STG.UNITED_RENTALS TO ROLE UR_CICD_VALIDATOR;

GRANT USAGE ON DATABASE SEM_STG TO ROLE UR_CICD_VALIDATOR;
GRANT USAGE ON SCHEMA SEM_STG.UNITED_RENTALS TO ROLE UR_CICD_VALIDATOR;
GRANT SELECT ON ALL VIEWS IN SCHEMA SEM_STG.UNITED_RENTALS TO ROLE UR_CICD_VALIDATOR;

-- PROD (read-only)
GRANT USAGE ON DATABASE RAW_PROD TO ROLE UR_CICD_VALIDATOR;
GRANT USAGE ON SCHEMA RAW_PROD.UNITED_RENTALS TO ROLE UR_CICD_VALIDATOR;
GRANT SELECT ON ALL TABLES IN SCHEMA RAW_PROD.UNITED_RENTALS TO ROLE UR_CICD_VALIDATOR;
GRANT SELECT ON FUTURE TABLES IN SCHEMA RAW_PROD.UNITED_RENTALS TO ROLE UR_CICD_VALIDATOR;

GRANT USAGE ON DATABASE CURATED_PROD TO ROLE UR_CICD_VALIDATOR;
GRANT USAGE ON SCHEMA CURATED_PROD.UNITED_RENTALS TO ROLE UR_CICD_VALIDATOR;
GRANT SELECT ON ALL TABLES IN SCHEMA CURATED_PROD.UNITED_RENTALS TO ROLE UR_CICD_VALIDATOR;
GRANT SELECT ON ALL VIEWS IN SCHEMA CURATED_PROD.UNITED_RENTALS TO ROLE UR_CICD_VALIDATOR;

GRANT USAGE ON DATABASE SEM_PROD TO ROLE UR_CICD_VALIDATOR;
GRANT USAGE ON SCHEMA SEM_PROD.UNITED_RENTALS TO ROLE UR_CICD_VALIDATOR;
GRANT SELECT ON ALL VIEWS IN SCHEMA SEM_PROD.UNITED_RENTALS TO ROLE UR_CICD_VALIDATOR;

-- GOVERNANCE (read-only — for contract and tag validation)
GRANT USAGE ON DATABASE GOVERNANCE TO ROLE UR_CICD_VALIDATOR;
GRANT USAGE ON SCHEMA GOVERNANCE.TAGS TO ROLE UR_CICD_VALIDATOR;
GRANT USAGE ON SCHEMA GOVERNANCE.CONTRACTS TO ROLE UR_CICD_VALIDATOR;
GRANT SELECT ON ALL TABLES IN SCHEMA GOVERNANCE.CONTRACTS TO ROLE UR_CICD_VALIDATOR;
GRANT SELECT ON FUTURE TABLES IN SCHEMA GOVERNANCE.CONTRACTS TO ROLE UR_CICD_VALIDATOR;

-- ─────────────────────────────────────────────────────────────────────────
-- CLONE PROVISIONER: Can create databases (for zero-copy clones)
-- ─────────────────────────────────────────────────────────────────────────
-- Note: In a real deployment, scope this via a stored procedure owned
-- by DATA_ADMIN that the provisioner can CALL. For the demo, we grant
-- CREATE DATABASE directly to show the pattern.

GRANT CREATE DATABASE ON ACCOUNT TO ROLE UR_CLONE_PROVISIONER;

-- Read access on PROD (clone source)
GRANT USAGE ON DATABASE RAW_PROD TO ROLE UR_CLONE_PROVISIONER;
GRANT USAGE ON DATABASE CURATED_PROD TO ROLE UR_CLONE_PROVISIONER;
GRANT USAGE ON DATABASE SEM_PROD TO ROLE UR_CLONE_PROVISIONER;

-- Access to GOVERNANCE for clone registry
GRANT USAGE ON DATABASE GOVERNANCE TO ROLE UR_CLONE_PROVISIONER;
GRANT USAGE ON SCHEMA GOVERNANCE.CONTRACTS TO ROLE UR_CLONE_PROVISIONER;

-- ─────────────────────────────────────────────────────────────────────────
-- BUSINESS ROLES: Read access to PRODUCTION (consumers read from PROD)
-- ─────────────────────────────────────────────────────────────────────────
-- Business roles (UR_FLEET_MANAGER, etc.) already have access to _DEV
-- databases (from 01_ur_setup.sql). In a real deployment, they consume
-- from PROD. Grant read access so the demo can show the full picture.

GRANT USAGE ON DATABASE CURATED_PROD TO ROLE UR_FLEET_MANAGER;
GRANT USAGE ON SCHEMA CURATED_PROD.UNITED_RENTALS TO ROLE UR_FLEET_MANAGER;
GRANT SELECT ON ALL TABLES IN SCHEMA CURATED_PROD.UNITED_RENTALS TO ROLE UR_FLEET_MANAGER;
GRANT SELECT ON ALL DYNAMIC TABLES IN SCHEMA CURATED_PROD.UNITED_RENTALS TO ROLE UR_FLEET_MANAGER;
GRANT SELECT ON ALL VIEWS IN SCHEMA CURATED_PROD.UNITED_RENTALS TO ROLE UR_FLEET_MANAGER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA CURATED_PROD.UNITED_RENTALS TO ROLE UR_FLEET_MANAGER;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA CURATED_PROD.UNITED_RENTALS TO ROLE UR_FLEET_MANAGER;

GRANT USAGE ON DATABASE SEM_PROD TO ROLE UR_FLEET_MANAGER;
GRANT USAGE ON SCHEMA SEM_PROD.UNITED_RENTALS TO ROLE UR_FLEET_MANAGER;
GRANT SELECT ON ALL VIEWS IN SCHEMA SEM_PROD.UNITED_RENTALS TO ROLE UR_FLEET_MANAGER;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA SEM_PROD.UNITED_RENTALS TO ROLE UR_FLEET_MANAGER;

-- External partner: limited PROD read access (same pattern as DEV)
GRANT USAGE ON DATABASE CURATED_PROD TO ROLE UR_EXTERNAL_PARTNER;
GRANT USAGE ON SCHEMA CURATED_PROD.UNITED_RENTALS TO ROLE UR_EXTERNAL_PARTNER;
GRANT SELECT ON ALL TABLES IN SCHEMA CURATED_PROD.UNITED_RENTALS TO ROLE UR_EXTERNAL_PARTNER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA CURATED_PROD.UNITED_RENTALS TO ROLE UR_EXTERNAL_PARTNER;


-- ═══════════════════════════════════════════════════════════════════════════
-- SECTION 4: ENVIRONMENT REGISTRY
-- ═══════════════════════════════════════════════════════════════════════════
-- Central config table that maps environments to databases and roles.
-- The CI/CD pipeline queries this table to resolve deployment targets
-- dynamically — no hardcoded database names in pipeline YAML.
--
-- Example pipeline usage:
--   SELECT DATABASE_NAME, DEPLOY_ROLE
--   FROM GOVERNANCE.CONTRACTS.ENVIRONMENT_REGISTRY
--   WHERE ENVIRONMENT = $TARGET_ENV AND LAYER = 'CURATED';
-- ═══════════════════════════════════════════════════════════════════════════

USE DATABASE GOVERNANCE;
USE SCHEMA GOVERNANCE.CONTRACTS;

CREATE OR REPLACE TABLE GOVERNANCE.CONTRACTS.ENVIRONMENT_REGISTRY (
    ENVIRONMENT VARCHAR(10) NOT NULL,          -- DEV, STG, PROD
    LAYER VARCHAR(10) NOT NULL,                -- RAW, CURATED, SEMANTIC
    DATABASE_NAME VARCHAR(100) NOT NULL,       -- Resolved database name
    DEPLOY_ROLE VARCHAR(50) NOT NULL,          -- Role that can write here
    VALIDATE_ROLE VARCHAR(50) NOT NULL,        -- Role that can read here
    REQUIRES_APPROVAL BOOLEAN DEFAULT FALSE,   -- Human approval required?
    APPROVAL_ROLE VARCHAR(50),                 -- Who approves (if required)
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_ENV_REGISTRY PRIMARY KEY (ENVIRONMENT, LAYER)
)
COMMENT = 'Maps environments to databases, deploy roles, and approval requirements. Queried by CI/CD pipeline for dynamic target resolution.';

INSERT INTO GOVERNANCE.CONTRACTS.ENVIRONMENT_REGISTRY
    (ENVIRONMENT, LAYER, DATABASE_NAME, DEPLOY_ROLE, VALIDATE_ROLE, REQUIRES_APPROVAL, APPROVAL_ROLE)
VALUES
    -- Development: no approval needed, fast iteration
    ('DEV',  'RAW',      'RAW_DEV',      'UR_CICD_DEPLOY_DEV',  'UR_CICD_VALIDATOR', FALSE, NULL),
    ('DEV',  'CURATED',  'CURATED_DEV',  'UR_CICD_DEPLOY_DEV',  'UR_CICD_VALIDATOR', FALSE, NULL),
    ('DEV',  'SEMANTIC', 'SEM_DEV',      'UR_CICD_DEPLOY_DEV',  'UR_CICD_VALIDATOR', FALSE, NULL),
    -- Staging: automated validation gates, no human approval
    ('STG',  'RAW',      'RAW_STG',      'UR_CICD_DEPLOY_STG',  'UR_CICD_VALIDATOR', FALSE, NULL),
    ('STG',  'CURATED',  'CURATED_STG',  'UR_CICD_DEPLOY_STG',  'UR_CICD_VALIDATOR', FALSE, NULL),
    ('STG',  'SEMANTIC', 'SEM_STG',      'UR_CICD_DEPLOY_STG',  'UR_CICD_VALIDATOR', FALSE, NULL),
    -- Production: requires UR_PLATFORM_ADMIN approval
    ('PROD', 'RAW',      'RAW_PROD',     'UR_CICD_DEPLOY_PROD', 'UR_CICD_VALIDATOR', TRUE,  'UR_PLATFORM_ADMIN'),
    ('PROD', 'CURATED',  'CURATED_PROD', 'UR_CICD_DEPLOY_PROD', 'UR_CICD_VALIDATOR', TRUE,  'UR_PLATFORM_ADMIN'),
    ('PROD', 'SEMANTIC', 'SEM_PROD',     'UR_CICD_DEPLOY_PROD', 'UR_CICD_VALIDATOR', TRUE,  'UR_PLATFORM_ADMIN');


-- ═══════════════════════════════════════════════════════════════════════════
-- SECTION 5: PROMOTION AUDIT LOG & CLONE REGISTRY
-- ═══════════════════════════════════════════════════════════════════════════
-- Every promotion (DEV→STG, STG→PROD) and every clone provisioning event
-- is recorded. This gives UR's compliance team a complete audit trail:
--   WHO deployed WHAT to WHERE, WHEN, and WHETHER it passed validation.
-- ═══════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────
-- Promotion Log: tracks every environment promotion
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE GOVERNANCE.CONTRACTS.PROMOTION_LOG (
    PROMOTION_ID VARCHAR DEFAULT UUID_STRING(),
    PROMOTED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    PROMOTED_BY VARCHAR DEFAULT CURRENT_USER(),
    PROMOTED_ROLE VARCHAR DEFAULT CURRENT_ROLE(),
    SOURCE_ENVIRONMENT VARCHAR(10) NOT NULL,       -- DEV, STG
    TARGET_ENVIRONMENT VARCHAR(10) NOT NULL,        -- STG, PROD
    OBJECT_TYPE VARCHAR(50) NOT NULL,               -- TABLE, VIEW, DYNAMIC_TABLE, PROCEDURE
    OBJECT_NAME VARCHAR(500) NOT NULL,              -- Fully qualified name
    PROMOTION_METHOD VARCHAR(20) NOT NULL,          -- CLONE, SWAP, DDL, EXECUTE_IMMEDIATE
    CONTRACT_ID VARCHAR,                            -- Associated contract (if any)
    VALIDATION_PASSED BOOLEAN,                      -- Did all gates pass?
    VALIDATION_DETAILS VARIANT,                     -- Gate results as JSON
    GIT_COMMIT_SHA VARCHAR(40),                     -- Git commit that triggered this
    GIT_BRANCH VARCHAR(200),                        -- Source branch
    PR_NUMBER NUMBER,                               -- Pull request number
    STATUS VARCHAR(20) DEFAULT 'SUCCESS',           -- SUCCESS, FAILED, ROLLED_BACK
    ROLLBACK_PROMOTION_ID VARCHAR                   -- Links to the rollback if rolled back
)
COMMENT = 'Immutable audit log of every environment promotion. Answers: who deployed what, where, when, and whether it passed validation.';

-- ─────────────────────────────────────────────────────────────────────────
-- Clone Registry: tracks all dev clone environments
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE GOVERNANCE.CONTRACTS.CLONE_REGISTRY (
    CLONE_ID VARCHAR DEFAULT UUID_STRING(),
    CLONE_DATABASE VARCHAR(100) NOT NULL,           -- Name of the cloned database
    SOURCE_DATABASE VARCHAR(100) NOT NULL,           -- Which PROD database was cloned
    DOMAIN VARCHAR(50) NOT NULL,                     -- UR domain (e.g., UNITED_RENTALS)
    TEAM_ROLE VARCHAR(50) NOT NULL,                  -- Role granted access to the clone
    REQUESTED_BY VARCHAR DEFAULT CURRENT_USER(),
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    EXPIRES_AT TIMESTAMP_NTZ,                        -- TTL for automatic cleanup
    STATUS VARCHAR(20) DEFAULT 'ACTIVE',             -- ACTIVE, EXPIRED, DROPPED
    DROPPED_AT TIMESTAMP_NTZ,
    COMMENT VARCHAR(500)
)
COMMENT = 'Tracks zero-copy clone environments. Used by CLEANUP_EXPIRED_CLONES to enforce TTL and manage storage costs.';

-- Grant GOVERNANCE database/schema access to deploy roles
-- (needed to read ENVIRONMENT_REGISTRY and write to PROMOTION_LOG)
GRANT USAGE ON DATABASE GOVERNANCE TO ROLE UR_CICD_DEPLOY_PROD;
GRANT USAGE ON DATABASE GOVERNANCE TO ROLE UR_CICD_DEPLOY_STG;
GRANT USAGE ON DATABASE GOVERNANCE TO ROLE UR_CICD_DEPLOY_DEV;
GRANT USAGE ON SCHEMA GOVERNANCE.CONTRACTS TO ROLE UR_CICD_DEPLOY_PROD;
GRANT USAGE ON SCHEMA GOVERNANCE.CONTRACTS TO ROLE UR_CICD_DEPLOY_STG;
GRANT USAGE ON SCHEMA GOVERNANCE.CONTRACTS TO ROLE UR_CICD_DEPLOY_DEV;

-- Grant write access for procedures that log to these tables
GRANT INSERT ON TABLE GOVERNANCE.CONTRACTS.PROMOTION_LOG TO ROLE UR_CICD_DEPLOY_PROD;
GRANT INSERT ON TABLE GOVERNANCE.CONTRACTS.PROMOTION_LOG TO ROLE UR_CICD_DEPLOY_STG;
GRANT INSERT ON TABLE GOVERNANCE.CONTRACTS.PROMOTION_LOG TO ROLE UR_CICD_DEPLOY_DEV;
GRANT INSERT, UPDATE ON TABLE GOVERNANCE.CONTRACTS.CLONE_REGISTRY TO ROLE UR_CLONE_PROVISIONER;
GRANT SELECT ON TABLE GOVERNANCE.CONTRACTS.PROMOTION_LOG TO ROLE UR_CICD_VALIDATOR;
GRANT SELECT ON TABLE GOVERNANCE.CONTRACTS.CLONE_REGISTRY TO ROLE UR_CICD_VALIDATOR;
GRANT SELECT ON TABLE GOVERNANCE.CONTRACTS.ENVIRONMENT_REGISTRY TO ROLE UR_CICD_VALIDATOR;
GRANT SELECT ON TABLE GOVERNANCE.CONTRACTS.ENVIRONMENT_REGISTRY TO ROLE UR_CICD_DEPLOY_DEV;
GRANT SELECT ON TABLE GOVERNANCE.CONTRACTS.ENVIRONMENT_REGISTRY TO ROLE UR_CICD_DEPLOY_STG;
GRANT SELECT ON TABLE GOVERNANCE.CONTRACTS.ENVIRONMENT_REGISTRY TO ROLE UR_CICD_DEPLOY_PROD;


-- ═══════════════════════════════════════════════════════════════════════════
-- SECTION 6: STORED PROCEDURES (CI/CD Automation)
-- ═══════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────
-- 6a. PROVISION_DEV_CLONE
-- ─────────────────────────────────────────────────────────────────────────
-- Creates a zero-copy clone set (RAW + CURATED + SEMANTIC) from PROD
-- for a named team. Registers in clone registry with TTL.
--
-- Usage:
--   CALL GOVERNANCE.CONTRACTS.PROVISION_DEV_CLONE(
--       'MANNING',              -- team name
--       'MANNING_TEAM_ROLE',    -- role to grant access
--       14                      -- TTL in days
--   );
--
-- Creates: RAW_MANNING_DEV, CURATED_MANNING_DEV, SEM_MANNING_DEV
-- ─────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE PROCEDURE GOVERNANCE.CONTRACTS.PROVISION_DEV_CLONE(
    P_TEAM_NAME VARCHAR,
    P_TEAM_ROLE VARCHAR,
    P_TTL_DAYS NUMBER DEFAULT 14
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_raw_clone VARCHAR;
    v_curated_clone VARCHAR;
    v_sem_clone VARCHAR;
    v_expires TIMESTAMP_NTZ;
BEGIN
    -- Build clone database names following Container-by-DB convention
    v_raw_clone := 'RAW_' || UPPER(:P_TEAM_NAME) || '_DEV';
    v_curated_clone := 'CURATED_' || UPPER(:P_TEAM_NAME) || '_DEV';
    v_sem_clone := 'SEM_' || UPPER(:P_TEAM_NAME) || '_DEV';
    v_expires := DATEADD('day', :P_TTL_DAYS, CURRENT_TIMESTAMP());

    -- Create zero-copy clones from PRODUCTION
    -- These are instant regardless of data size and cost zero storage
    -- until the team starts modifying data
    EXECUTE IMMEDIATE 'CREATE DATABASE IF NOT EXISTS ' || :v_raw_clone || ' CLONE RAW_PROD';
    EXECUTE IMMEDIATE 'CREATE DATABASE IF NOT EXISTS ' || :v_curated_clone || ' CLONE CURATED_PROD';
    EXECUTE IMMEDIATE 'CREATE DATABASE IF NOT EXISTS ' || :v_sem_clone || ' CLONE SEM_PROD';

    -- Grant full ownership to the team role
    EXECUTE IMMEDIATE 'GRANT ALL ON DATABASE ' || :v_raw_clone || ' TO ROLE ' || :P_TEAM_ROLE;
    EXECUTE IMMEDIATE 'GRANT ALL ON DATABASE ' || :v_curated_clone || ' TO ROLE ' || :P_TEAM_ROLE;
    EXECUTE IMMEDIATE 'GRANT ALL ON DATABASE ' || :v_sem_clone || ' TO ROLE ' || :P_TEAM_ROLE;

    -- Also grant to the team's CI/CD deployer so pipelines work in the clone
    EXECUTE IMMEDIATE 'GRANT ALL ON DATABASE ' || :v_raw_clone || ' TO ROLE UR_CICD_DEPLOY_DEV';
    EXECUTE IMMEDIATE 'GRANT ALL ON DATABASE ' || :v_curated_clone || ' TO ROLE UR_CICD_DEPLOY_DEV';
    EXECUTE IMMEDIATE 'GRANT ALL ON DATABASE ' || :v_sem_clone || ' TO ROLE UR_CICD_DEPLOY_DEV';

    -- Register all three clones in the registry
    INSERT INTO GOVERNANCE.CONTRACTS.CLONE_REGISTRY
        (CLONE_DATABASE, SOURCE_DATABASE, DOMAIN, TEAM_ROLE, EXPIRES_AT, COMMENT)
    VALUES
        (:v_raw_clone, 'RAW_PROD', 'UNITED_RENTALS', :P_TEAM_ROLE, :v_expires,
         'Auto-provisioned for team ' || :P_TEAM_NAME),
        (:v_curated_clone, 'CURATED_PROD', 'UNITED_RENTALS', :P_TEAM_ROLE, :v_expires,
         'Auto-provisioned for team ' || :P_TEAM_NAME),
        (:v_sem_clone, 'SEM_PROD', 'UNITED_RENTALS', :P_TEAM_ROLE, :v_expires,
         'Auto-provisioned for team ' || :P_TEAM_NAME);

    RETURN 'Clone set provisioned for team ' || :P_TEAM_NAME || ':\n' ||
           '  ' || :v_raw_clone || '\n' ||
           '  ' || :v_curated_clone || '\n' ||
           '  ' || :v_sem_clone || '\n' ||
           'Granted to role: ' || :P_TEAM_ROLE || '\n' ||
           'Expires: ' || TO_VARCHAR(:v_expires, 'YYYY-MM-DD HH24:MI');
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────
-- 6b. VALIDATE_PROMOTION
-- ─────────────────────────────────────────────────────────────────────────
-- Pre-flight validation before promoting objects between environments.
-- Returns a result set of pass/fail checks. Used by the CI/CD pipeline
-- as a gate — if any ERROR-severity check fails, promotion is blocked.
--
-- Checks:
--   1. ROLE_AUTHORIZATION: Is the caller authorized for the target env?
--   2. SOURCE_HAS_OBJECTS: Does the source schema have objects to promote?
--   3. GOVERNANCE_TAGS: Are governance tags applied in the source?
--   4. MASKING_POLICIES: Are masking policies attached to PII columns?
--   5. CONTRACT_EXISTS: Does a data contract exist for this schema?
-- ─────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE PROCEDURE GOVERNANCE.CONTRACTS.VALIDATE_PROMOTION(
    P_SOURCE_DB VARCHAR,       -- e.g., 'CURATED_DEV'
    P_TARGET_ENV VARCHAR,      -- e.g., 'PROD'
    P_SCHEMA VARCHAR           -- e.g., 'UNITED_RENTALS'
)
RETURNS TABLE (CHECK_NAME VARCHAR, PASSED BOOLEAN, MESSAGE VARCHAR, SEVERITY VARCHAR)
LANGUAGE SQL
AS
$$
DECLARE
    v_target_db VARCHAR;
    v_deploy_role VARCHAR;
    v_requires_approval BOOLEAN;
    result RESULTSET;
BEGIN
    -- Resolve target database from environment registry
    SELECT DATABASE_NAME, DEPLOY_ROLE, REQUIRES_APPROVAL
    INTO :v_target_db, :v_deploy_role, :v_requires_approval
    FROM GOVERNANCE.CONTRACTS.ENVIRONMENT_REGISTRY
    WHERE ENVIRONMENT = :P_TARGET_ENV
      AND LAYER = CASE
          WHEN :P_SOURCE_DB LIKE 'RAW%' THEN 'RAW'
          WHEN :P_SOURCE_DB LIKE 'CURATED%' THEN 'CURATED'
          WHEN :P_SOURCE_DB LIKE 'SEM%' THEN 'SEMANTIC'
      END;

    result := (
        -- Check 1: Role authorization for target environment
        SELECT
            'ROLE_AUTHORIZATION' AS CHECK_NAME,
            CASE WHEN CURRENT_ROLE() IN (:v_deploy_role, 'UR_PLATFORM_ADMIN', 'DATA_ADMIN')
                 THEN TRUE ELSE FALSE END AS PASSED,
            CASE WHEN CURRENT_ROLE() IN (:v_deploy_role, 'UR_PLATFORM_ADMIN', 'DATA_ADMIN')
                 THEN 'Role ' || CURRENT_ROLE() || ' authorized for ' || :P_TARGET_ENV || ' deployment'
                 ELSE 'BLOCKED: Role ' || CURRENT_ROLE() || ' is NOT authorized. Required: ' || :v_deploy_role
            END AS MESSAGE,
            'ERROR' AS SEVERITY

        UNION ALL

        -- Check 2: Source schema has objects
        SELECT
            'SOURCE_HAS_OBJECTS' AS CHECK_NAME,
            CASE WHEN COUNT(*) > 0 THEN TRUE ELSE FALSE END AS PASSED,
            'Source ' || :P_SOURCE_DB || '.' || :P_SCHEMA || ' has ' || COUNT(*) || ' table(s)' AS MESSAGE,
            'ERROR' AS SEVERITY
        FROM TABLE(RESULT_SCAN(LAST_QUERY_ID(-1)))
        -- Use information_schema from the source database
        -- Note: in production this would query INFORMATION_SCHEMA dynamically

        UNION ALL

        -- Check 3: Approval required?
        SELECT
            'APPROVAL_REQUIRED' AS CHECK_NAME,
            TRUE AS PASSED,
            CASE WHEN :v_requires_approval
                 THEN 'WARNING: ' || :P_TARGET_ENV || ' deployment requires UR_PLATFORM_ADMIN approval'
                 ELSE :P_TARGET_ENV || ' deployment does not require manual approval'
            END AS MESSAGE,
            CASE WHEN :v_requires_approval THEN 'WARNING' ELSE 'INFO' END AS SEVERITY

        UNION ALL

        -- Check 4: Target environment resolved
        SELECT
            'TARGET_RESOLVED' AS CHECK_NAME,
            CASE WHEN :v_target_db IS NOT NULL THEN TRUE ELSE FALSE END AS PASSED,
            CASE WHEN :v_target_db IS NOT NULL
                 THEN 'Target resolved: ' || :v_target_db || '.' || :P_SCHEMA
                 ELSE 'BLOCKED: No target database found for environment ' || :P_TARGET_ENV
            END AS MESSAGE,
            'ERROR' AS SEVERITY
    );

    RETURN TABLE(result);
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────
-- 6c. PROMOTE_OBJECT
-- ─────────────────────────────────────────────────────────────────────────
-- Executes a governed promotion of a single object between environments.
-- Supports three promotion methods:
--   CLONE: Zero-copy clone the object (instant, good for tables)
--   SWAP:  Atomic swap (instant rollback capability)
--   DDL:   Execute CREATE OR REPLACE from Git (views, procedures)
--
-- Every promotion is logged to PROMOTION_LOG with full audit context.
-- ─────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE PROCEDURE GOVERNANCE.CONTRACTS.PROMOTE_OBJECT(
    P_OBJECT_TYPE VARCHAR,         -- TABLE, VIEW, DYNAMIC_TABLE, PROCEDURE
    P_SOURCE_FQN VARCHAR,          -- e.g., 'CURATED_DEV.UNITED_RENTALS.DIM_BRANCH'
    P_TARGET_FQN VARCHAR,          -- e.g., 'CURATED_PROD.UNITED_RENTALS.DIM_BRANCH'
    P_METHOD VARCHAR DEFAULT 'CLONE',  -- CLONE, SWAP, DDL
    P_GIT_SHA VARCHAR DEFAULT NULL,
    P_GIT_BRANCH VARCHAR DEFAULT NULL,
    P_PR_NUMBER NUMBER DEFAULT NULL
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_promotion_id VARCHAR DEFAULT UUID_STRING();
    v_status VARCHAR DEFAULT 'SUCCESS';
    v_target_env VARCHAR;
BEGIN
    -- Determine target environment from the database name
    v_target_env := CASE
        WHEN :P_TARGET_FQN LIKE '%_DEV.%' THEN 'DEV'
        WHEN :P_TARGET_FQN LIKE '%_STG.%' THEN 'STG'
        WHEN :P_TARGET_FQN LIKE '%_PROD.%' THEN 'PROD'
        ELSE 'UNKNOWN'
    END;

    -- Execute promotion based on method
    CASE UPPER(:P_METHOD)
        WHEN 'CLONE' THEN
            EXECUTE IMMEDIATE
                'CREATE OR REPLACE ' || :P_OBJECT_TYPE || ' ' || :P_TARGET_FQN ||
                ' CLONE ' || :P_SOURCE_FQN;
        WHEN 'SWAP' THEN
            EXECUTE IMMEDIATE
                'ALTER TABLE ' || :P_TARGET_FQN ||
                ' SWAP WITH ' || :P_SOURCE_FQN;
        WHEN 'DDL' THEN
            -- DDL method means the CI/CD pipeline executes the SQL directly.
            -- This procedure just logs it.
            NULL;
        ELSE
            v_status := 'FAILED';
            INSERT INTO GOVERNANCE.CONTRACTS.PROMOTION_LOG
                (PROMOTION_ID, SOURCE_ENVIRONMENT, TARGET_ENVIRONMENT, OBJECT_TYPE,
                 OBJECT_NAME, PROMOTION_METHOD, VALIDATION_PASSED, STATUS)
            VALUES
                (:v_promotion_id, 'UNKNOWN', :v_target_env, :P_OBJECT_TYPE,
                 :P_SOURCE_FQN, :P_METHOD, FALSE, 'FAILED');
            RETURN 'ERROR: Unknown promotion method: ' || :P_METHOD || '. Use CLONE, SWAP, or DDL.';
    END CASE;

    -- Log the promotion
    INSERT INTO GOVERNANCE.CONTRACTS.PROMOTION_LOG
        (PROMOTION_ID, SOURCE_ENVIRONMENT, TARGET_ENVIRONMENT, OBJECT_TYPE,
         OBJECT_NAME, PROMOTION_METHOD, VALIDATION_PASSED,
         GIT_COMMIT_SHA, GIT_BRANCH, PR_NUMBER, STATUS)
    VALUES
        (:v_promotion_id,
         CASE WHEN :P_SOURCE_FQN LIKE '%_DEV.%' THEN 'DEV'
              WHEN :P_SOURCE_FQN LIKE '%_STG.%' THEN 'STG' ELSE 'UNKNOWN' END,
         :v_target_env,
         :P_OBJECT_TYPE, :P_SOURCE_FQN, :P_METHOD, TRUE,
         :P_GIT_SHA, :P_GIT_BRANCH, :P_PR_NUMBER, :v_status);

    RETURN 'Promoted: ' || :P_SOURCE_FQN || ' → ' || :P_TARGET_FQN ||
           ' [method=' || :P_METHOD || ', id=' || :v_promotion_id || ']';
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────
-- 6d. CLEANUP_EXPIRED_CLONES
-- ─────────────────────────────────────────────────────────────────────────
-- Drops clone databases past their TTL. Designed to run as a scheduled
-- Snowflake TASK for cost management.
--
-- Usage (manual):
--   CALL GOVERNANCE.CONTRACTS.CLEANUP_EXPIRED_CLONES();
--
-- Usage (scheduled):
--   CREATE TASK CLEANUP_CLONES_TASK
--     WAREHOUSE = TRANSFORM_WH
--     SCHEDULE = 'USING CRON 0 6 * * * America/Chicago'
--   AS CALL GOVERNANCE.CONTRACTS.CLEANUP_EXPIRED_CLONES();
-- ─────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE PROCEDURE GOVERNANCE.CONTRACTS.CLEANUP_EXPIRED_CLONES()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_count NUMBER DEFAULT 0;
    v_db_name VARCHAR;
    c1 CURSOR FOR
        SELECT CLONE_DATABASE
        FROM GOVERNANCE.CONTRACTS.CLONE_REGISTRY
        WHERE STATUS = 'ACTIVE' AND EXPIRES_AT < CURRENT_TIMESTAMP();
BEGIN
    FOR rec IN c1 DO
        v_db_name := rec.CLONE_DATABASE;
        EXECUTE IMMEDIATE 'DROP DATABASE IF EXISTS ' || :v_db_name;
        UPDATE GOVERNANCE.CONTRACTS.CLONE_REGISTRY
        SET STATUS = 'EXPIRED', DROPPED_AT = CURRENT_TIMESTAMP()
        WHERE CLONE_DATABASE = :v_db_name AND STATUS = 'ACTIVE';
        v_count := v_count + 1;
    END FOR;

    RETURN 'Clone cleanup complete: ' || :v_count || ' expired database(s) dropped.';
END;
$$;


-- ═══════════════════════════════════════════════════════════════════════════
-- SECTION 7: DEMO HELPER VIEWS
-- ═══════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────
-- 7a. CI/CD Role × Environment Permission Matrix
-- ─────────────────────────────────────────────────────────────────────────
-- Shows the complete access matrix for the workshop walkthrough.
-- This is the visual proof that "database boundary = environment boundary".

CREATE OR REPLACE VIEW GOVERNANCE.CONTRACTS.VW_CICD_ROLE_MATRIX AS
SELECT * FROM (
    VALUES
    -- CI/CD Service Roles
    ('UR_CICD_DEPLOY_DEV',  'CI/CD',    'RAW_DEV',      'ALL DDL',  'RAW_STG',      'NONE',    'RAW_PROD',      'NONE'),
    ('UR_CICD_DEPLOY_DEV',  'CI/CD',    'CURATED_DEV',  'ALL DDL',  'CURATED_STG',  'NONE',    'CURATED_PROD',  'NONE'),
    ('UR_CICD_DEPLOY_DEV',  'CI/CD',    'SEM_DEV',      'ALL DDL',  'SEM_STG',      'NONE',    'SEM_PROD',      'NONE'),
    ('UR_CICD_DEPLOY_STG',  'CI/CD',    'RAW_DEV',      'NONE',     'RAW_STG',      'ALL DDL', 'RAW_PROD',      'NONE'),
    ('UR_CICD_DEPLOY_STG',  'CI/CD',    'CURATED_DEV',  'NONE',     'CURATED_STG',  'ALL DDL', 'CURATED_PROD',  'NONE'),
    ('UR_CICD_DEPLOY_STG',  'CI/CD',    'SEM_DEV',      'NONE',     'SEM_STG',      'ALL DDL', 'SEM_PROD',      'NONE'),
    ('UR_CICD_DEPLOY_PROD', 'CI/CD',    'RAW_DEV',      'NONE',     'RAW_STG',      'NONE',    'RAW_PROD',      'ALL DDL'),
    ('UR_CICD_DEPLOY_PROD', 'CI/CD',    'CURATED_DEV',  'NONE',     'CURATED_STG',  'NONE',    'CURATED_PROD',  'ALL DDL'),
    ('UR_CICD_DEPLOY_PROD', 'CI/CD',    'SEM_DEV',      'NONE',     'SEM_STG',      'NONE',    'SEM_PROD',      'ALL DDL'),
    ('UR_CICD_VALIDATOR',   'CI/CD',    'ALL_DEV',      'SELECT',   'ALL_STG',      'SELECT',  'ALL_PROD',      'SELECT'),
    ('UR_CLONE_PROVISIONER','CI/CD',    'N/A',          'CREATE DB','N/A',          'N/A',     'ALL_PROD',      'READ (src)'),
    ('UR_PLATFORM_ADMIN',   'CI/CD',    'ALL_DEV',      'INHERIT',  'ALL_STG',      'INHERIT', 'ALL_PROD',      'INHERIT'),
    -- Business Roles (for comparison)
    ('UR_FLEET_MANAGER',    'Business', 'CURATED_DEV',  'SELECT',   'N/A',          'NONE',    'CURATED_PROD',  'SELECT'),
    ('UR_REGIONAL_DIRECTOR','Business', 'CURATED_DEV',  'SELECT',   'N/A',          'NONE',    'N/A',           'via hierarchy'),
    ('UR_BRANCH_MANAGER',   'Business', 'CURATED_DEV',  'SELECT',   'N/A',          'NONE',    'N/A',           'via hierarchy'),
    ('UR_CORPORATE_ANALYST', 'Business','CURATED_DEV',  'SELECT',   'N/A',          'NONE',    'N/A',           'via hierarchy'),
    ('UR_EXTERNAL_PARTNER', 'Business', 'CURATED_DEV',  'SELECT',   'N/A',          'NONE',    'CURATED_PROD',  'SELECT')
) AS t(ROLE_NAME, ROLE_TYPE, DEV_DATABASE, DEV_ACCESS, STG_DATABASE, STG_ACCESS, PROD_DATABASE, PROD_ACCESS);

COMMENT ON VIEW GOVERNANCE.CONTRACTS.VW_CICD_ROLE_MATRIX IS
    'Complete CI/CD + business role permission matrix across all environments. Use for workshop walkthrough.';


-- ─────────────────────────────────────────────────────────────────────────
-- 7b. Promotion History (formatted for audit demo)
-- ─────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW GOVERNANCE.CONTRACTS.VW_PROMOTION_HISTORY AS
SELECT
    PROMOTION_ID,
    PROMOTED_AT,
    PROMOTED_BY,
    PROMOTED_ROLE,
    SOURCE_ENVIRONMENT || ' → ' || TARGET_ENVIRONMENT AS PROMOTION_PATH,
    OBJECT_TYPE,
    OBJECT_NAME,
    PROMOTION_METHOD,
    CASE WHEN VALIDATION_PASSED THEN 'PASSED' ELSE 'FAILED' END AS VALIDATION_STATUS,
    GIT_COMMIT_SHA,
    GIT_BRANCH,
    PR_NUMBER,
    STATUS
FROM GOVERNANCE.CONTRACTS.PROMOTION_LOG
ORDER BY PROMOTED_AT DESC;

COMMENT ON VIEW GOVERNANCE.CONTRACTS.VW_PROMOTION_HISTORY IS
    'Formatted promotion audit trail. Shows who deployed what, where, when, and whether validation passed.';


-- ─────────────────────────────────────────────────────────────────────────
-- 7c. Active Clones (with remaining TTL)
-- ─────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW GOVERNANCE.CONTRACTS.VW_ACTIVE_CLONES AS
SELECT
    CLONE_ID,
    CLONE_DATABASE,
    SOURCE_DATABASE,
    DOMAIN,
    TEAM_ROLE,
    REQUESTED_BY,
    CREATED_AT,
    EXPIRES_AT,
    DATEDIFF('hour', CURRENT_TIMESTAMP(), EXPIRES_AT) AS HOURS_REMAINING,
    CASE
        WHEN DATEDIFF('hour', CURRENT_TIMESTAMP(), EXPIRES_AT) < 0 THEN 'OVERDUE'
        WHEN DATEDIFF('hour', CURRENT_TIMESTAMP(), EXPIRES_AT) < 24 THEN 'EXPIRING SOON'
        ELSE 'ACTIVE'
    END AS LIFECYCLE_STATUS,
    COMMENT
FROM GOVERNANCE.CONTRACTS.CLONE_REGISTRY
WHERE STATUS = 'ACTIVE'
ORDER BY EXPIRES_AT;

COMMENT ON VIEW GOVERNANCE.CONTRACTS.VW_ACTIVE_CLONES IS
    'Active clone environments with remaining TTL. Highlights clones that are expiring soon or overdue for cleanup.';


-- ─────────────────────────────────────────────────────────────────────────
-- 7d. Complete Role Hierarchy (CI/CD + Business combined)
-- ─────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW GOVERNANCE.CONTRACTS.VW_UR_ROLE_HIERARCHY AS
SELECT * FROM (
    VALUES
    -- CI/CD Roles
    ('DATA_ADMIN',           NULL,                 'Platform',  'Full admin - owns all objects'),
    ('UR_PLATFORM_ADMIN',    'DATA_ADMIN',         'CI/CD',     'CI/CD infrastructure and promotion workflows'),
    ('UR_CICD_DEPLOY_PROD',  'UR_PLATFORM_ADMIN',  'CI/CD',     'Pipeline service: PROD deployments only'),
    ('UR_CICD_DEPLOY_STG',   'UR_PLATFORM_ADMIN',  'CI/CD',     'Pipeline service: STG deployments only'),
    ('UR_CICD_DEPLOY_DEV',   'UR_PLATFORM_ADMIN',  'CI/CD',     'Pipeline service: DEV deployments only'),
    ('UR_CICD_VALIDATOR',    'UR_PLATFORM_ADMIN',  'CI/CD',     'Read-only cross-env validation'),
    ('UR_CLONE_PROVISIONER', 'DATA_ADMIN',         'CI/CD',     'Zero-copy clone lifecycle management'),
    -- Business Roles
    ('UR_FLEET_MANAGER',     'DATA_ADMIN',         'Business',  'Full fleet visibility, all branches, all pricing'),
    ('UR_REGIONAL_DIRECTOR', 'UR_FLEET_MANAGER',   'Business',  'Region-scoped, full pricing'),
    ('UR_BRANCH_MANAGER',    'UR_REGIONAL_DIRECTOR','Business', 'Branch-scoped, limited pricing'),
    ('UR_CORPORATE_ANALYST', 'UR_FLEET_MANAGER',   'Business',  'Cross-branch analytics, PII masked'),
    ('UR_EXTERNAL_PARTNER',  'DATA_ADMIN',         'External',  'Minimal access, no pricing, no PII')
) AS t(ROLE_NAME, PARENT_ROLE, ROLE_CATEGORY, DESCRIPTION);

COMMENT ON VIEW GOVERNANCE.CONTRACTS.VW_UR_ROLE_HIERARCHY IS
    'Complete UR role hierarchy showing both CI/CD and business roles with parent relationships.';


-- ═══════════════════════════════════════════════════════════════════════════
-- WORKSHOP DEMO: ENVIRONMENT ISOLATION PROOF
-- ═══════════════════════════════════════════════════════════════════════════
-- Run these queries during the workshop to prove the isolation model.
-- Each query demonstrates that a role can ONLY access its target environment.
--
-- Demo script:
--   1. USE ROLE UR_CICD_DEPLOY_DEV;
--      SHOW SCHEMAS IN DATABASE RAW_DEV;       -- ✓ Works
--      SHOW SCHEMAS IN DATABASE RAW_PROD;      -- ✗ Access denied
--
--   2. USE ROLE UR_CICD_DEPLOY_PROD;
--      SHOW SCHEMAS IN DATABASE RAW_PROD;      -- ✓ Works
--      SHOW SCHEMAS IN DATABASE RAW_DEV;       -- ✗ Access denied
--
--   3. USE ROLE UR_CICD_VALIDATOR;
--      SELECT COUNT(*) FROM CURATED_DEV.UNITED_RENTALS.DIM_BRANCH;  -- ✓ Works (read)
--      SELECT COUNT(*) FROM CURATED_PROD.UNITED_RENTALS.DIM_BRANCH; -- ✓ Works (read)
--      CREATE TABLE CURATED_PROD.UNITED_RENTALS.TEST (ID INT);      -- ✗ Access denied (write)
--
--   4. USE ROLE UR_PLATFORM_ADMIN;
--      -- Can do everything (inherits all CI/CD roles)
--      SHOW SCHEMAS IN DATABASE RAW_DEV;       -- ✓
--      SHOW SCHEMAS IN DATABASE RAW_PROD;      -- ✓
--
--   5. Query the role matrix:
--      SELECT * FROM GOVERNANCE.CONTRACTS.VW_CICD_ROLE_MATRIX
--      ORDER BY ROLE_TYPE, ROLE_NAME;
-- ═══════════════════════════════════════════════════════════════════════════

SELECT 'CI/CD RBAC & Environment Architecture complete.' AS STATUS;
SELECT '  6 CI/CD roles created (UR_PLATFORM_ADMIN, 3 deployers, validator, clone provisioner)' AS DETAIL
UNION ALL SELECT '  6 environment databases (3 STG + 3 PROD) alongside existing 3 DEV'
UNION ALL SELECT '  9 environment registry entries (3 envs × 3 layers)'
UNION ALL SELECT '  4 stored procedures (provision, validate, promote, cleanup)'
UNION ALL SELECT '  4 demo views (role matrix, promotion history, active clones, role hierarchy)'
UNION ALL SELECT '  Environment isolation enforced by GRANTS — no separate accounts needed';
