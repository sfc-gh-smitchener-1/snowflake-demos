-- ============================================================================
-- SUTTER HEALTH DEMO — Curated Layer: Dynamic Tables
-- ============================================================================
--
-- Creates four Dynamic Tables in CURATED_DEV.SUTTER_HEALTH that auto-refresh
-- from the raw layer. These power the semantic views and Cortex Analyst queries.
--
--   DIM_MEMBER        — Current member snapshot (latest enrollment record)
--   DIM_PROVIDER      — Provider directory with quality metrics
--   FACT_CLAIMS       — Enriched claim lines joined to member + provider
--   FACT_RISK_ADJ     — Member-level risk adjustment summary
--
-- TARGET_LAG = '1 hour' supports near-real-time analytics without
-- always-on compute (auto-suspend between refreshes).
--
-- Prerequisites: 03_sh_load_data.sql
-- RUN AS: DATA_ADMIN
-- ============================================================================

USE ROLE DATA_ADMIN;
USE DATABASE CURATED_DEV;
USE SCHEMA SUTTER_HEALTH;
USE WAREHOUSE TRANSFORM_WH;

-- ═══════════════════════════════════════════════════════════════════════════
-- DIM_MEMBER — Current enrollment snapshot
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE DYNAMIC TABLE CURATED_DEV.SUTTER_HEALTH.DIM_MEMBER
    TARGET_LAG = '1 hour'
    WAREHOUSE = TRANSFORM_WH
    COMMENT = 'Current member enrollment snapshot. Auto-refreshes from RAW_DEV.SUTTER_HEALTH.MEMBER_ENROLLMENT.'
AS
SELECT
    e.MEMBER_ID,
    e.SUBSCRIBER_ID,
    e.MBI_NUMBER,
    e.MEMBER_RELATIONSHIP,
    e.PLAN_ID,
    e.PLAN_NAME,
    e.PLAN_TYPE,
    e.PRODUCT_LINE,
    e.GROUP_NUMBER,
    e.EMPLOYER_NAME,
    e.DATE_OF_BIRTH,
    e.GENDER,
    -- Age calculation
    DATEDIFF('year', e.DATE_OF_BIRTH, CURRENT_DATE()) AS AGE_YEARS,
    CASE
        WHEN DATEDIFF('year', e.DATE_OF_BIRTH, CURRENT_DATE()) < 18  THEN '0-17'
        WHEN DATEDIFF('year', e.DATE_OF_BIRTH, CURRENT_DATE()) < 35  THEN '18-34'
        WHEN DATEDIFF('year', e.DATE_OF_BIRTH, CURRENT_DATE()) < 50  THEN '35-49'
        WHEN DATEDIFF('year', e.DATE_OF_BIRTH, CURRENT_DATE()) < 65  THEN '50-64'
        ELSE '65+'
    END AS AGE_BAND,
    e.ZIP_CODE,
    e.COUNTY_CODE,
    e.STATE_CODE,
    e.COVERAGE_START_DATE,
    e.COVERAGE_END_DATE,
    e.ENROLLMENT_STATUS,
    e.COBRA_FLAG,
    e.DUAL_ELIGIBLE,
    e.LIS_LEVEL,
    -- Risk fields
    e.RISK_SCORE,
    e.PRIOR_YEAR_RISK_SCORE,
    e.RISK_SCORE - COALESCE(e.PRIOR_YEAR_RISK_SCORE, e.RISK_SCORE) AS RISK_SCORE_DELTA,
    e.RISK_CATEGORY,
    e.RISK_PERCENTILE,
    e.PROSPECTIVE_RISK_SCORE,
    e.CARE_MANAGEMENT_FLAG,
    e.CHRONIC_CONDITION_COUNT,
    e.PRIMARY_CARE_NPI,
    e._LOADED_AT
FROM RAW_DEV.SUTTER_HEALTH.MEMBER_ENROLLMENT e
WHERE e._IS_CURRENT = TRUE;

-- ═══════════════════════════════════════════════════════════════════════════
-- DIM_PROVIDER — Provider directory with enriched quality tier
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE DYNAMIC TABLE CURATED_DEV.SUTTER_HEALTH.DIM_PROVIDER
    TARGET_LAG = '1 hour'
    WAREHOUSE = TRANSFORM_WH
    COMMENT = 'Active provider directory with quality metrics. Auto-refreshes from RAW_DEV.SUTTER_HEALTH.PROVIDER_DIRECTORY.'
AS
SELECT
    p.PROVIDER_NPI,
    p.GROUP_NPI,
    p.PROVIDER_LAST_NAME,
    p.PROVIDER_FIRST_NAME,
    p.PROVIDER_LAST_NAME || COALESCE(', ' || p.PROVIDER_FIRST_NAME, '') AS PROVIDER_FULL_NAME,
    p.PROVIDER_CREDENTIAL,
    p.SPECIALTY_CODE,
    p.SPECIALTY_DESC,
    p.TAXONOMY_CODE,
    p.PRIMARY_CARE_FLAG,
    p.NETWORK_STATUS,
    p.NETWORK_EFFECTIVE_DATE,
    p.ACCEPTING_NEW_PATIENTS,
    p.TELEHEALTH_ENABLED,
    p.QUALITY_TIER,
    p.PRACTICE_CITY,
    p.PRACTICE_STATE,
    p.PRACTICE_ZIP,
    p.PRACTICE_COUNTY_CODE,
    p.PRACTICE_LATITUDE,
    p.PRACTICE_LONGITUDE,
    p.CREDENTIAL_STATUS,
    p.CREDENTIAL_EXPIRY_DATE,
    p.BOARD_CERTIFIED,
    p.MALPRACTICE_FLAG,
    p.CLAIM_VOLUME_30D,
    p.RISK_FLAG_VOLUME_30D,
    p.AVG_RISK_SCORE_PANEL,
    -- Derived quality flag for demo
    CASE
        WHEN p.QUALITY_TIER = 'TIER_1' AND p.BOARD_CERTIFIED = TRUE AND p.MALPRACTICE_FLAG = FALSE THEN 'HIGH_VALUE'
        WHEN p.QUALITY_TIER = 'TIER_2' AND p.MALPRACTICE_FLAG = FALSE                              THEN 'STANDARD'
        WHEN p.MALPRACTICE_FLAG = TRUE OR p.CREDENTIAL_STATUS != 'ACTIVE'                           THEN 'FLAGGED'
        ELSE 'STANDARD'
    END AS PROVIDER_QUALITY_RATING
FROM RAW_DEV.SUTTER_HEALTH.PROVIDER_DIRECTORY p
WHERE p.NETWORK_STATUS != 'TERMINATED';

-- ═══════════════════════════════════════════════════════════════════════════
-- FACT_CLAIMS — Enriched claim lines
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE DYNAMIC TABLE CURATED_DEV.SUTTER_HEALTH.FACT_CLAIMS
    TARGET_LAG = '1 hour'
    WAREHOUSE = TRANSFORM_WH
    COMMENT = 'Enriched claim lines joined to member enrollment and provider. Powers Cortex Analyst SLA and cost queries.'
AS
SELECT
    c.CLAIM_ID,
    c.CLAIM_LINE_NUMBER,
    c.MEMBER_ID,
    c.PROVIDER_NPI,

    -- Claim classification
    c.CLAIM_TYPE,
    c.CLAIM_SUBTYPE,
    c.PLACE_OF_SERVICE_CODE,
    c.PLACE_OF_SERVICE_DESC,

    -- Diagnosis / procedure
    c.PRIMARY_DX_CODE,
    c.SECONDARY_DX_CODE_1,
    c.PROCEDURE_CODE,
    c.DRG_CODE,

    -- HCC category prefix mapping (for risk category display)
    CASE
        WHEN c.PRIMARY_DX_CODE LIKE 'E11%' OR c.PRIMARY_DX_CODE LIKE 'E10%' THEN 'DIABETES'
        WHEN c.PRIMARY_DX_CODE LIKE 'I21%' OR c.PRIMARY_DX_CODE LIKE 'I50%' THEN 'CARDIAC'
        WHEN c.PRIMARY_DX_CODE LIKE 'J44%' OR c.PRIMARY_DX_CODE LIKE 'J43%' THEN 'RESPIRATORY'
        WHEN c.PRIMARY_DX_CODE LIKE 'N18%' OR c.PRIMARY_DX_CODE LIKE 'N17%' THEN 'RENAL'
        WHEN c.PRIMARY_DX_CODE LIKE 'C%'                                     THEN 'ONCOLOGY'
        WHEN c.PRIMARY_DX_CODE LIKE 'F%'                                     THEN 'BEHAVIORAL_HEALTH'
        WHEN c.PRIMARY_DX_CODE LIKE 'M%'                                     THEN 'MUSCULOSKELETAL'
        ELSE 'OTHER'
    END AS CLINICAL_CATEGORY,

    -- Financial
    c.BILLED_AMOUNT,
    c.ALLOWED_AMOUNT,
    c.PAID_AMOUNT,
    c.MEMBER_RESPONSIBILITY,
    c.CLAIM_STATUS,
    c.DENIAL_REASON_CODE,

    -- Dates
    c.SERVICE_DATE,
    c.PLAN_YEAR,
    DATE_TRUNC('month', c.SERVICE_DATE) AS SERVICE_MONTH,
    DATE_TRUNC('quarter', c.SERVICE_DATE) AS SERVICE_QUARTER,

    -- SLA — primary demo metrics
    c.CLAIM_RECEIVED_TS,
    c.CLAIM_PROCESSED_TS,
    c.SLA_TARGET_HOURS,
    c.SLA_MET,
    c.SLA_BREACH_HOURS,
    c.PROCESSING_HOURS,

    -- Network
    c.NETWORK_STATUS,

    -- Member dimensions (denormalized for query convenience)
    m.PLAN_TYPE,
    m.PRODUCT_LINE,
    m.RISK_CATEGORY AS MEMBER_RISK_CATEGORY,
    m.RISK_SCORE AS MEMBER_RISK_SCORE,
    m.AGE_BAND,
    m.STATE_CODE AS MEMBER_STATE,
    m.DUAL_ELIGIBLE,

    -- Provider dimensions
    p.SPECIALTY_DESC AS PROVIDER_SPECIALTY,
    p.QUALITY_TIER AS PROVIDER_QUALITY_TIER,
    p.PROVIDER_FULL_NAME,
    p.PRIMARY_CARE_FLAG AS IS_PCP_CLAIM,
    p.PRACTICE_STATE AS PROVIDER_STATE

FROM RAW_DEV.SUTTER_HEALTH.RAW_CLAIMS c
LEFT JOIN CURATED_DEV.SUTTER_HEALTH.DIM_MEMBER m
    ON c.MEMBER_ID = m.MEMBER_ID
LEFT JOIN CURATED_DEV.SUTTER_HEALTH.DIM_PROVIDER p
    ON c.PROVIDER_NPI = p.PROVIDER_NPI;

-- ═══════════════════════════════════════════════════════════════════════════
-- FACT_RISK_ADJ — Member-level risk adjustment summary
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE DYNAMIC TABLE CURATED_DEV.SUTTER_HEALTH.FACT_RISK_ADJ
    TARGET_LAG = '1 hour'
    WAREHOUSE = TRANSFORM_WH
    COMMENT = 'Member-level risk adjustment summary aggregated from flags and claims. Supports Cortex Analyst risk queries.'
AS
SELECT
    f.MEMBER_ID,
    f.PLAN_YEAR,
    COUNT(DISTINCT f.FLAG_ID)                               AS TOTAL_HCC_FLAGS,
    COUNT(DISTINCT f.HCC_CODE)                              AS UNIQUE_HCC_CATEGORIES,
    SUM(f.RISK_WEIGHT)                                      AS TOTAL_RISK_WEIGHT,
    AVG(f.RISK_WEIGHT)                                      AS AVG_HCC_WEIGHT,
    MAX(f.RISK_WEIGHT)                                      AS MAX_HCC_WEIGHT,
    ARRAY_AGG(DISTINCT f.HCC_CODE)                          AS HCC_CODE_ARRAY,
    ARRAY_AGG(DISTINCT f.ICD10_CODE) WITHIN GROUP (ORDER BY f.ICD10_CODE) AS DX_CODE_ARRAY,
    COUNT(CASE WHEN f.FLAG_SOURCE = 'CLAIMS'         THEN 1 END) AS FLAGS_FROM_CLAIMS,
    COUNT(CASE WHEN f.FLAG_SOURCE = 'CHART_REVIEW'   THEN 1 END) AS FLAGS_FROM_CHART,
    COUNT(CASE WHEN f.FLAG_SOURCE = 'PROSPECTIVE'    THEN 1 END) AS FLAGS_PROSPECTIVE,
    COUNT(CASE WHEN f.CLAIM_SLA_MET = FALSE          THEN 1 END) AS FLAGS_WITH_SLA_BREACH,
    AVG(f.CLAIM_PROCESSING_HOURS)                           AS AVG_CLAIM_PROCESSING_HRS,
    MAX(f.RUN_DATE)                                         AS LAST_PIPELINE_RUN,
    -- Join to member risk score
    m.RISK_SCORE,
    m.RISK_CATEGORY,
    m.RISK_PERCENTILE,
    m.CARE_MANAGEMENT_FLAG,
    m.CHRONIC_CONDITION_COUNT,
    m.PLAN_TYPE,
    m.PRODUCT_LINE,
    m.AGE_BAND,
    m.STATE_CODE AS MEMBER_STATE
FROM RAW_DEV.SUTTER_HEALTH.RISK_ADJUSTMENT_FLAGS f
JOIN CURATED_DEV.SUTTER_HEALTH.DIM_MEMBER m
    ON f.MEMBER_ID = m.MEMBER_ID
WHERE f.FLAG_STATUS = 'ACTIVE'
GROUP BY
    f.MEMBER_ID, f.PLAN_YEAR,
    m.RISK_SCORE, m.RISK_CATEGORY, m.RISK_PERCENTILE,
    m.CARE_MANAGEMENT_FLAG, m.CHRONIC_CONDITION_COUNT,
    m.PLAN_TYPE, m.PRODUCT_LINE, m.AGE_BAND, m.STATE_CODE;
