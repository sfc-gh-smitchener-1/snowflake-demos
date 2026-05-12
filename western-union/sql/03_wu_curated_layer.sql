-- ============================================================================
-- WESTERN UNION — CDO ENGAGEMENT: CURATED LAYER (Dynamic Tables)
-- ============================================================================
-- Demonstrates how Dynamic Tables with TARGET_LAG create the Silver/Curated
-- layer automatically. Each Dynamic Table selects from the RAW_DEV source,
-- applies business-friendly naming, and refreshes on a schedule appropriate
-- to the data's velocity.
--
-- Schema Structure:
--   CURATED_DEV.WU_PAYMENTS    — Transaction facts, corridor/agent dimensions
--   CURATED_DEV.WU_KYC         — Customer, beneficiary, device dimensions
--   CURATED_DEV.WU_COMPLIANCE  — Watchlist dimension, SAR facts
--
-- PREREQUISITES:
--   - sql/01_setup.sql executed (databases, roles exist)
--   - sql/05_curated_layer.sql executed (CURATED_DEV database and shared schemas)
--   - 01_wu_setup.sql executed (RAW_DEV schemas)
--   - 02_wu_load_data.sql executed (data loaded into RAW_DEV)
--
-- NOTE: quality_issues stays in RAW only — it is the "bad data" the contract
--       system will catch. No Dynamic Table is created for it.
--
-- RUN AS: DATA_ADMIN
-- ============================================================================

USE ROLE DATA_ADMIN;
USE DATABASE CURATED_DEV;
USE WAREHOUSE COMPUTE_WH;

-- ═══════════════════════════════════════════════════════════════════════════
-- CREATE WU SCHEMAS IN CURATED_DEV
-- ═══════════════════════════════════════════════════════════════════════════

CREATE SCHEMA IF NOT EXISTS CURATED_DEV.WU_PAYMENTS
    COMMENT = 'Western Union payment processing curated dimensions and facts';

CREATE SCHEMA IF NOT EXISTS CURATED_DEV.WU_KYC
    COMMENT = 'Western Union KYC/CRM curated dimensions and facts';

CREATE SCHEMA IF NOT EXISTS CURATED_DEV.WU_COMPLIANCE
    COMMENT = 'Western Union compliance/sanctions curated dimensions and facts';

-- ═══════════════════════════════════════════════════════════════════════════
-- WU_PAYMENTS DYNAMIC TABLES
-- ═══════════════════════════════════════════════════════════════════════════

-- DIM_CORRIDOR: Remittance corridors (origin → destination country pairs)
CREATE OR REPLACE DYNAMIC TABLE CURATED_DEV.WU_PAYMENTS.DIM_CORRIDOR
    TARGET_LAG = '24 hours'
    WAREHOUSE = COMPUTE_WH
    COMMENT = 'Remittance corridors — country pairs with risk classification'
AS
SELECT
    "corridor_id"          AS CORRIDOR_ID,
    "corridor_code"        AS CORRIDOR_CODE,
    "origin_country"       AS ORIGIN_COUNTRY,
    "dest_country"         AS DEST_COUNTRY,
    "risk_tier"            AS RISK_TIER,
    "regulatory_regime"    AS REGULATORY_REGIME,
    "avg_daily_volume"     AS AVG_DAILY_VOLUME,
    "is_active"            AS IS_ACTIVE
FROM RAW_DEV.WU_PAYMENTS.CORRIDORS;

-- DIM_AGENT: Agent network (retail locations, digital partners)
CREATE OR REPLACE DYNAMIC TABLE CURATED_DEV.WU_PAYMENTS.DIM_AGENT
    TARGET_LAG = '1 hour'
    WAREHOUSE = COMPUTE_WH
    COMMENT = 'Agent network — retail and digital partners with compliance scores'
AS
SELECT
    "agent_id"              AS AGENT_ID,
    "agent_name"            AS AGENT_NAME,
    "country"               AS COUNTRY,
    "city"                  AS CITY,
    "agent_type"            AS AGENT_TYPE,
    "compliance_score"      AS COMPLIANCE_SCORE,
    "monthly_volume"        AS MONTHLY_VOLUME,
    "sar_count"             AS SAR_COUNT,
    "kyc_completion_rate"   AS KYC_COMPLETION_RATE,
    "is_active"             AS IS_ACTIVE
FROM RAW_DEV.WU_PAYMENTS.AGENTS;

-- FACT_TRANSACTIONS: Near real-time transaction stream
CREATE OR REPLACE DYNAMIC TABLE CURATED_DEV.WU_PAYMENTS.FACT_TRANSACTIONS
    TARGET_LAG = '1 minute'
    WAREHOUSE = COMPUTE_WH
    COMMENT = 'Near real-time transaction stream — the core fact table for WU analytics'
AS
SELECT
    "transaction_id"       AS TRANSACTION_ID,
    "sender_id"            AS SENDER_ID,
    "receiver_id"          AS RECEIVER_ID,
    "amount_usd"           AS AMOUNT_USD,
    "amount_local"         AS AMOUNT_LOCAL,
    "currency_local"       AS CURRENCY_LOCAL,
    "fx_rate"              AS FX_RATE,
    "corridor"             AS CORRIDOR,
    "channel"              AS CHANNEL,
    "agent_id"             AS AGENT_ID,
    "payment_method"       AS PAYMENT_METHOD,
    "status"               AS STATUS,
    "compliance_hold"      AS COMPLIANCE_HOLD,
    "hold_reason"          AS HOLD_REASON,
    "created_at"           AS CREATED_AT,
    "completed_at"         AS COMPLETED_AT,
    "fee_usd"              AS FEE_USD
FROM RAW_DEV.WU_PAYMENTS.TRANSACTIONS;

-- ═══════════════════════════════════════════════════════════════════════════
-- WU_KYC DYNAMIC TABLES
-- ═══════════════════════════════════════════════════════════════════════════

-- DIM_CUSTOMER: Customer identity and KYC status
CREATE OR REPLACE DYNAMIC TABLE CURATED_DEV.WU_KYC.DIM_CUSTOMER
    TARGET_LAG = '1 hour'
    WAREHOUSE = COMPUTE_WH
    COMMENT = 'Customer identity and KYC status — single current-state view'
AS
SELECT
    "customer_id"          AS CUSTOMER_ID,
    "full_name"            AS FULL_NAME,
    "country"              AS COUNTRY,
    "state"                AS STATE,
    "city"                 AS CITY,
    "kyc_status"           AS KYC_STATUS,
    "kyc_method"           AS KYC_METHOD,
    "kyc_date"             AS KYC_DATE,
    "kyc_expiry_date"      AS KYC_EXPIRY_DATE,
    "risk_level"           AS RISK_LEVEL,
    "source_of_funds"      AS SOURCE_OF_FUNDS,
    "occupation"           AS OCCUPATION,
    "lifetime_value_usd"   AS LIFETIME_VALUE_USD,
    "account_created_at"   AS ACCOUNT_CREATED_AT
FROM RAW_DEV.WU_KYC.CUSTOMERS;

-- DIM_BENEFICIARY: Beneficiary (receiver) profiles
CREATE OR REPLACE DYNAMIC TABLE CURATED_DEV.WU_KYC.DIM_BENEFICIARY
    TARGET_LAG = '1 hour'
    WAREHOUSE = COMPUTE_WH
    COMMENT = 'Beneficiary profiles — receivers linked to customers'
AS
SELECT
    "beneficiary_id"       AS BENEFICIARY_ID,
    "customer_id"          AS CUSTOMER_ID,
    "full_name"            AS FULL_NAME,
    "country"              AS COUNTRY,
    "city"                 AS CITY,
    "bank_name"            AS BANK_NAME,
    "relationship_type"    AS RELATIONSHIP_TYPE,
    "total_transfers"      AS TOTAL_TRANSFERS,
    "total_amount_usd"     AS TOTAL_AMOUNT_USD
FROM RAW_DEV.WU_KYC.BENEFICIARIES;

-- DIM_DEVICE: Customer device fingerprints
CREATE OR REPLACE DYNAMIC TABLE CURATED_DEV.WU_KYC.DIM_DEVICE
    TARGET_LAG = '4 hours'
    WAREHOUSE = COMPUTE_WH
    COMMENT = 'Customer device fingerprints — digital channel trust signals'
AS
SELECT
    "device_id"            AS DEVICE_ID,
    "customer_id"          AS CUSTOMER_ID,
    "platform"             AS PLATFORM,
    "device_model"         AS DEVICE_MODEL,
    "ip_country"           AS IP_COUNTRY,
    "first_seen"           AS FIRST_SEEN,
    "last_seen"            AS LAST_SEEN,
    "is_trusted"           AS IS_TRUSTED
FROM RAW_DEV.WU_KYC.DEVICES;

-- ═══════════════════════════════════════════════════════════════════════════
-- WU_COMPLIANCE DYNAMIC TABLES
-- ═══════════════════════════════════════════════════════════════════════════

-- DIM_WATCHLIST: Sanctions and watchlist entities
CREATE OR REPLACE DYNAMIC TABLE CURATED_DEV.WU_COMPLIANCE.DIM_WATCHLIST
    TARGET_LAG = '1 hour'
    WAREHOUSE = COMPUTE_WH
    COMMENT = 'Sanctions and watchlist entities — OFAC, UN, EU, and internal lists'
AS
SELECT
    "entity_id"            AS ENTITY_ID,
    "entity_name"          AS ENTITY_NAME,
    "list_source"          AS LIST_SOURCE,
    "entity_type"          AS ENTITY_TYPE,
    "country"              AS COUNTRY,
    "aliases"              AS ALIASES,
    "added_date"           AS ADDED_DATE
FROM RAW_DEV.WU_COMPLIANCE.WATCHLIST_ENTITIES;

-- FACT_SARS: Suspicious Activity Reports
CREATE OR REPLACE DYNAMIC TABLE CURATED_DEV.WU_COMPLIANCE.FACT_SARS
    TARGET_LAG = '5 minutes'
    WAREHOUSE = COMPUTE_WH
    COMMENT = 'Suspicious Activity Reports — near real-time compliance filings'
AS
SELECT
    "sar_id"                    AS SAR_ID,
    "customer_id"               AS CUSTOMER_ID,
    "filing_type"               AS FILING_TYPE,
    "amount_threshold_trigger"  AS AMOUNT_THRESHOLD_TRIGGER,
    "total_amount"              AS TOTAL_AMOUNT,
    "filing_date"               AS FILING_DATE,
    "narrative"                 AS NARRATIVE,
    "status"                    AS STATUS
FROM RAW_DEV.WU_COMPLIANCE.SARS;

-- ═══════════════════════════════════════════════════════════════════════════
-- VERIFICATION QUERIES
-- ═══════════════════════════════════════════════════════════════════════════

-- Dynamic Table inventory
SELECT
    TABLE_SCHEMA    AS DOMAIN,
    TABLE_NAME,
    COMMENT
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_CATALOG = 'CURATED_DEV'
  AND TABLE_SCHEMA IN ('WU_PAYMENTS', 'WU_KYC', 'WU_COMPLIANCE')
  AND TABLE_TYPE = 'DYNAMIC TABLE'
ORDER BY TABLE_SCHEMA, TABLE_NAME;

SELECT '03_wu_curated_layer.sql completed successfully' AS STATUS;
