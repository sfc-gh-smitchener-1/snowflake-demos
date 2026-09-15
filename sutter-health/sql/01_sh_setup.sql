-- ============================================================================
-- SUTTER HEALTH DEMO — Setup: Schemas, Roles, Warehouse, Governance Tags
-- ============================================================================
--
-- Creates Sutter Health-specific infrastructure within the DCA framework:
--   - Schemas under existing RAW_DEV, CURATED_DEV, SEM_DEV databases
--   - 4 SH-specific roles demonstrating graduated RBAC for a health plan
--   - Governance tags: PHI classification, SLA tier, risk category
--
-- Prerequisites: core DCA sql/01_setup.sql through sql/05_curated_layer.sql
-- RUN AS: DATA_ADMIN
-- ============================================================================

USE ROLE DATA_ADMIN;
USE WAREHOUSE TRANSFORM_WH;

-- ═══════════════════════════════════════════════════════════════════════════
-- SCHEMAS (one per DCA database tier)
-- ═══════════════════════════════════════════════════════════════════════════

CREATE SCHEMA IF NOT EXISTS RAW_DEV.SUTTER_HEALTH
    COMMENT = 'Sutter Health raw claims and enrollment data (Epic + Payer feeds)';

CREATE SCHEMA IF NOT EXISTS CURATED_DEV.SUTTER_HEALTH
    COMMENT = 'Sutter Health curated dimensions and facts (Dynamic Tables)';

CREATE SCHEMA IF NOT EXISTS SEM_DEV.SUTTER_HEALTH
    COMMENT = 'Sutter Health semantic views for Cortex Analyst NL queries';

-- ═══════════════════════════════════════════════════════════════════════════
-- ROLES — Health plan RBAC hierarchy
--
--   DATA_ADMIN
--     └── SH_RISK_MANAGER         Full claims + risk access, PII visible
--           ├── SH_CLAIMS_ANALYST Claims data, SLA metrics, no PII
--           └── SH_EXECUTIVE      Summary/aggregated only, no PII, no line items
--
-- External auditor role (read-only, masked)
--           └── SH_AUDITOR        Masked PII, risk scores only
-- ═══════════════════════════════════════════════════════════════════════════

CREATE ROLE IF NOT EXISTS SH_RISK_MANAGER
    COMMENT = 'Sutter Health: Full claims and risk adjustment access, PII visible';

CREATE ROLE IF NOT EXISTS SH_CLAIMS_ANALYST
    COMMENT = 'Sutter Health: Claims and SLA analytics, PHI masked';

CREATE ROLE IF NOT EXISTS SH_EXECUTIVE
    COMMENT = 'Sutter Health: Executive summary access — aggregated metrics only';

CREATE ROLE IF NOT EXISTS SH_AUDITOR
    COMMENT = 'Sutter Health: External auditor — masked PII, risk scores only';

-- Hierarchy
GRANT ROLE SH_CLAIMS_ANALYST TO ROLE SH_RISK_MANAGER;
GRANT ROLE SH_EXECUTIVE      TO ROLE SH_RISK_MANAGER;
GRANT ROLE SH_AUDITOR        TO ROLE SH_CLAIMS_ANALYST;

-- Attach to DATA_ADMIN for demo use
GRANT ROLE SH_RISK_MANAGER TO ROLE DATA_ADMIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- SCHEMA GRANTS
-- ═══════════════════════════════════════════════════════════════════════════

-- RAW_DEV.SUTTER_HEALTH
GRANT USAGE ON DATABASE RAW_DEV TO ROLE SH_RISK_MANAGER;
GRANT USAGE ON SCHEMA RAW_DEV.SUTTER_HEALTH TO ROLE SH_RISK_MANAGER;
GRANT SELECT ON ALL TABLES IN SCHEMA RAW_DEV.SUTTER_HEALTH TO ROLE SH_RISK_MANAGER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA RAW_DEV.SUTTER_HEALTH TO ROLE SH_RISK_MANAGER;

GRANT USAGE ON DATABASE RAW_DEV TO ROLE SH_CLAIMS_ANALYST;
GRANT USAGE ON SCHEMA RAW_DEV.SUTTER_HEALTH TO ROLE SH_CLAIMS_ANALYST;
GRANT SELECT ON ALL TABLES IN SCHEMA RAW_DEV.SUTTER_HEALTH TO ROLE SH_CLAIMS_ANALYST;
GRANT SELECT ON FUTURE TABLES IN SCHEMA RAW_DEV.SUTTER_HEALTH TO ROLE SH_CLAIMS_ANALYST;

-- CURATED_DEV.SUTTER_HEALTH
GRANT USAGE ON DATABASE CURATED_DEV TO ROLE SH_RISK_MANAGER;
GRANT USAGE ON SCHEMA CURATED_DEV.SUTTER_HEALTH TO ROLE SH_RISK_MANAGER;
GRANT SELECT ON ALL TABLES IN SCHEMA CURATED_DEV.SUTTER_HEALTH TO ROLE SH_RISK_MANAGER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA CURATED_DEV.SUTTER_HEALTH TO ROLE SH_RISK_MANAGER;

GRANT USAGE ON DATABASE CURATED_DEV TO ROLE SH_CLAIMS_ANALYST;
GRANT USAGE ON SCHEMA CURATED_DEV.SUTTER_HEALTH TO ROLE SH_CLAIMS_ANALYST;
GRANT SELECT ON ALL TABLES IN SCHEMA CURATED_DEV.SUTTER_HEALTH TO ROLE SH_CLAIMS_ANALYST;
GRANT SELECT ON FUTURE TABLES IN SCHEMA CURATED_DEV.SUTTER_HEALTH TO ROLE SH_CLAIMS_ANALYST;

GRANT USAGE ON DATABASE CURATED_DEV TO ROLE SH_EXECUTIVE;
GRANT USAGE ON SCHEMA CURATED_DEV.SUTTER_HEALTH TO ROLE SH_EXECUTIVE;
GRANT SELECT ON ALL TABLES IN SCHEMA CURATED_DEV.SUTTER_HEALTH TO ROLE SH_EXECUTIVE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA CURATED_DEV.SUTTER_HEALTH TO ROLE SH_EXECUTIVE;

-- SEM_DEV.SUTTER_HEALTH
GRANT USAGE ON DATABASE SEM_DEV TO ROLE SH_RISK_MANAGER;
GRANT USAGE ON DATABASE SEM_DEV TO ROLE SH_CLAIMS_ANALYST;
GRANT USAGE ON DATABASE SEM_DEV TO ROLE SH_EXECUTIVE;
GRANT USAGE ON DATABASE SEM_DEV TO ROLE SH_AUDITOR;
GRANT USAGE ON SCHEMA SEM_DEV.SUTTER_HEALTH TO ROLE SH_RISK_MANAGER;
GRANT USAGE ON SCHEMA SEM_DEV.SUTTER_HEALTH TO ROLE SH_CLAIMS_ANALYST;
GRANT USAGE ON SCHEMA SEM_DEV.SUTTER_HEALTH TO ROLE SH_EXECUTIVE;
GRANT USAGE ON SCHEMA SEM_DEV.SUTTER_HEALTH TO ROLE SH_AUDITOR;

-- ═══════════════════════════════════════════════════════════════════════════
-- GOVERNANCE TAGS (PHI classification + SLA tier + risk category)
-- ═══════════════════════════════════════════════════════════════════════════

USE DATABASE RAW_DEV;
USE SCHEMA SUTTER_HEALTH;

CREATE TAG IF NOT EXISTS RAW_DEV.SUTTER_HEALTH.PHI_CLASSIFICATION
    ALLOWED_VALUES 'PHI', 'DE_IDENTIFIED', 'AGGREGATE', 'PUBLIC'
    COMMENT = 'HIPAA PHI sensitivity classification';

CREATE TAG IF NOT EXISTS RAW_DEV.SUTTER_HEALTH.SLA_TIER
    ALLOWED_VALUES 'CRITICAL_24HR', 'STANDARD_72HR', 'BATCH_WEEKLY'
    COMMENT = 'CMS/contractual SLA tier for claims processing';

CREATE TAG IF NOT EXISTS RAW_DEV.SUTTER_HEALTH.RISK_DOMAIN
    ALLOWED_VALUES 'HCC_RISK', 'CLAIMS_ADJUDICATION', 'MEMBER_MGMT', 'PROVIDER_CREDENTIALING'
    COMMENT = 'Risk adjustment and operational domain classification';

-- ═══════════════════════════════════════════════════════════════════════════
-- WAREHOUSE — XS for the risk adjustment pipeline (cost demo point)
-- ═══════════════════════════════════════════════════════════════════════════

CREATE WAREHOUSE IF NOT EXISTS SH_RISK_WH
    WAREHOUSE_SIZE = XSMALL
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    COMMENT = 'Sutter Health risk adjustment pipeline — XS warehouse for cost comparison demo';

GRANT USAGE ON WAREHOUSE SH_RISK_WH TO ROLE SH_RISK_MANAGER;
GRANT USAGE ON WAREHOUSE SH_RISK_WH TO ROLE SH_CLAIMS_ANALYST;
GRANT USAGE ON WAREHOUSE ANALYTICS_WH TO ROLE SH_RISK_MANAGER;
GRANT USAGE ON WAREHOUSE ANALYTICS_WH TO ROLE SH_CLAIMS_ANALYST;
GRANT USAGE ON WAREHOUSE ANALYTICS_WH TO ROLE SH_EXECUTIVE;
GRANT USAGE ON WAREHOUSE ANALYTICS_WH TO ROLE SH_AUDITOR;
