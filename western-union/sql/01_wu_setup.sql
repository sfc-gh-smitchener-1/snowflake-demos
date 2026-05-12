-- ============================================================================
-- WESTERN UNION — CDO ENGAGEMENT: SCHEMA SETUP
-- ============================================================================
-- Creates WU-specific schemas in RAW_DEV for three source systems:
--   - WU_PAYMENTS:    Payment processing engine (transactions, corridors, agents)
--   - WU_KYC:         KYC/CRM system (customers, beneficiaries, devices)
--   - WU_COMPLIANCE:  Compliance/sanctions (watchlists, SARs, quality issues)
--
-- PREREQUISITES:
--   - sql/01_setup.sql executed (databases, roles exist)
--
-- RUN AS: DATA_ADMIN
-- ============================================================================

USE ROLE DATA_ADMIN;
USE DATABASE RAW_DEV;
USE WAREHOUSE INGEST_WH;

-- ═══════════════════════════════════════════════════════════════════════════
-- WU SOURCE SYSTEM SCHEMAS
-- ═══════════════════════════════════════════════════════════════════════════

-- Western Union payment processing engine (transactions, corridors, agents)
CREATE SCHEMA IF NOT EXISTS RAW_DEV.WU_PAYMENTS
    COMMENT = 'Western Union payment processing engine (transactions, corridors, agents)';

-- Western Union KYC/CRM system (customers, beneficiaries, devices)
CREATE SCHEMA IF NOT EXISTS RAW_DEV.WU_KYC
    COMMENT = 'Western Union KYC/CRM system (customers, beneficiaries, devices)';

-- Western Union compliance/sanctions (watchlists, SARs, quality issues)
CREATE SCHEMA IF NOT EXISTS RAW_DEV.WU_COMPLIANCE
    COMMENT = 'Western Union compliance/sanctions (watchlists, SARs, quality issues)';

-- ═══════════════════════════════════════════════════════════════════════════
-- GRANTS — DATA_ENGINEER and DATA_STEWARD access
-- ═══════════════════════════════════════════════════════════════════════════

-- DATA_ENGINEER: full control on WU schemas
GRANT ALL ON SCHEMA RAW_DEV.WU_PAYMENTS TO ROLE DATA_ENGINEER;
GRANT ALL ON SCHEMA RAW_DEV.WU_KYC TO ROLE DATA_ENGINEER;
GRANT ALL ON SCHEMA RAW_DEV.WU_COMPLIANCE TO ROLE DATA_ENGINEER;

-- DATA_STEWARD: read-only
GRANT USAGE ON SCHEMA RAW_DEV.WU_PAYMENTS TO ROLE DATA_STEWARD;
GRANT USAGE ON SCHEMA RAW_DEV.WU_KYC TO ROLE DATA_STEWARD;
GRANT USAGE ON SCHEMA RAW_DEV.WU_COMPLIANCE TO ROLE DATA_STEWARD;

GRANT SELECT ON ALL TABLES IN SCHEMA RAW_DEV.WU_PAYMENTS TO ROLE DATA_STEWARD;
GRANT SELECT ON ALL TABLES IN SCHEMA RAW_DEV.WU_KYC TO ROLE DATA_STEWARD;
GRANT SELECT ON ALL TABLES IN SCHEMA RAW_DEV.WU_COMPLIANCE TO ROLE DATA_STEWARD;

GRANT SELECT ON FUTURE TABLES IN SCHEMA RAW_DEV.WU_PAYMENTS TO ROLE DATA_STEWARD;
GRANT SELECT ON FUTURE TABLES IN SCHEMA RAW_DEV.WU_KYC TO ROLE DATA_STEWARD;
GRANT SELECT ON FUTURE TABLES IN SCHEMA RAW_DEV.WU_COMPLIANCE TO ROLE DATA_STEWARD;

SELECT '01_wu_setup.sql completed successfully' AS STATUS;
