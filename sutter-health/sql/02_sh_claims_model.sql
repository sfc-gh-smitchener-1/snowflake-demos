-- ============================================================================
-- SUTTER HEALTH DEMO — Claims Data Model: Five Raw Tables
-- ============================================================================
--
-- Creates the raw healthcare claims data model in RAW_DEV.SUTTER_HEALTH:
--   1. RAW_CLAIMS            — adjudicated claim lines with SLA tracking
--   2. MEMBER_ENROLLMENT     — plan membership with risk scores
--   3. PROVIDER_DIRECTORY    — credentialed providers and network status
--   4. RISK_ADJUSTMENT_FLAGS — HCC flags from daily risk adjustment run
--   5. CLAIMS_SUMMARY        — member-level summary rollups
--
-- All tables include SCD2 metadata columns (from DCA convention) plus
-- SLA tracking timestamps and risk adjustment scores.
--
-- Prerequisites: 01_sh_setup.sql
-- RUN AS: DATA_ADMIN
-- ============================================================================

USE ROLE DATA_ADMIN;
USE DATABASE RAW_DEV;
USE SCHEMA SUTTER_HEALTH;
USE WAREHOUSE TRANSFORM_WH;

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. RAW_CLAIMS — Adjudicated claim lines
--    Source: Epic Clarity Claims, 837/835 EDI transactions
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS RAW_DEV.SUTTER_HEALTH.RAW_CLAIMS (
    -- Primary identifiers
    CLAIM_ID                VARCHAR(36)     NOT NULL    COMMENT 'Unique claim identifier (UUID)',
    CLAIM_LINE_NUMBER       INTEGER         NOT NULL    COMMENT 'Line item number within claim',
    MEMBER_ID               VARCHAR(36)     NOT NULL    COMMENT 'FK → MEMBER_ENROLLMENT.MEMBER_ID',
    PROVIDER_NPI            VARCHAR(10)     NOT NULL    COMMENT 'FK → PROVIDER_DIRECTORY.PROVIDER_NPI',

    -- Claim classification
    CLAIM_TYPE              VARCHAR(30)     NOT NULL    COMMENT 'PROFESSIONAL, INSTITUTIONAL, DENTAL, PHARMACY',
    CLAIM_SUBTYPE           VARCHAR(50)                 COMMENT 'INPATIENT, OUTPATIENT, ER, PREVENTIVE, SPECIALIST',
    BILL_TYPE_CODE          VARCHAR(4)                  COMMENT 'UB-04 bill type (institutional only)',
    PLACE_OF_SERVICE_CODE   VARCHAR(2)                  COMMENT 'CMS POS code (11=Office, 21=Inpatient, 23=ER)',
    PLACE_OF_SERVICE_DESC   VARCHAR(100)                COMMENT 'Human-readable POS description',

    -- Diagnosis and procedure
    PRIMARY_DX_CODE         VARCHAR(10)     NOT NULL    COMMENT 'Primary ICD-10-CM diagnosis code',
    SECONDARY_DX_CODE_1     VARCHAR(10)                 COMMENT 'Secondary ICD-10-CM code 1',
    SECONDARY_DX_CODE_2     VARCHAR(10)                 COMMENT 'Secondary ICD-10-CM code 2',
    PROCEDURE_CODE          VARCHAR(10)                 COMMENT 'CPT or HCPCS procedure code',
    PROCEDURE_MODIFIER      VARCHAR(10)                 COMMENT 'CPT modifier (25, 59, GT, etc.)',
    REVENUE_CODE            VARCHAR(4)                  COMMENT 'UB-04 revenue code (institutional)',
    DRG_CODE                VARCHAR(5)                  COMMENT 'MS-DRG for inpatient claims',

    -- Financial
    BILLED_AMOUNT           DECIMAL(12,2)   NOT NULL    COMMENT 'Billed charge amount',
    ALLOWED_AMOUNT          DECIMAL(12,2)               COMMENT 'Contractual allowed amount',
    PAID_AMOUNT             DECIMAL(12,2)               COMMENT 'Actual payment to provider',
    MEMBER_RESPONSIBILITY   DECIMAL(12,2)               COMMENT 'Deductible + copay + coinsurance',
    COINSURANCE_AMOUNT      DECIMAL(12,2)               COMMENT 'Member coinsurance portion',
    COPAY_AMOUNT            DECIMAL(12,2)               COMMENT 'Member copay',
    DEDUCTIBLE_AMOUNT       DECIMAL(12,2)               COMMENT 'Applied to deductible',

    -- Claim status and adjudication
    CLAIM_STATUS            VARCHAR(20)     NOT NULL    COMMENT 'PAID, DENIED, PENDING, ADJUSTED, APPEALED, VOIDED',
    DENIAL_REASON_CODE      VARCHAR(10)                 COMMENT 'CARC denial reason code (CO-4, CO-96, PR-1, etc.)',
    DENIAL_REASON_DESC      VARCHAR(200)                COMMENT 'Human-readable denial reason',
    PAYER_CLAIM_CONTROL_NUM VARCHAR(30)                 COMMENT 'Payer ICN / claim control number',

    -- Dates
    SERVICE_DATE            DATE            NOT NULL    COMMENT 'Date of service (DTOS)',
    SERVICE_DATE_END        DATE                        COMMENT 'End date of service (multi-day stays)',
    CLAIM_SUBMISSION_DATE   DATE                        COMMENT 'Date submitted by provider',
    ADJUDICATION_DATE       DATE                        COMMENT 'Date claim was adjudicated',
    PLAN_YEAR               INTEGER         NOT NULL    COMMENT 'Benefit plan year',

    -- SLA tracking — key demo columns
    CLAIM_RECEIVED_TS       TIMESTAMP_NTZ   NOT NULL    COMMENT 'Timestamp when claim entered adjudication queue',
    CLAIM_PROCESSED_TS      TIMESTAMP_NTZ               COMMENT 'Timestamp when adjudication completed',
    SLA_TARGET_HOURS        INTEGER         NOT NULL DEFAULT 24  COMMENT 'Contractual SLA target in hours',
    SLA_MET                 BOOLEAN                     COMMENT 'TRUE if processed within SLA target',
    SLA_BREACH_HOURS        DECIMAL(8,2)                COMMENT 'Hours over SLA (NULL if met, positive if breached)',
    PROCESSING_HOURS        DECIMAL(8,2)                COMMENT 'Total hours from received to processed',

    -- Network and authorization
    NETWORK_STATUS          VARCHAR(20)                 COMMENT 'IN_NETWORK, OUT_OF_NETWORK, PREFERRED',
    PRIOR_AUTH_NUMBER       VARCHAR(30)                 COMMENT 'Prior authorization reference number',
    REFERRAL_NUMBER         VARCHAR(30)                 COMMENT 'Referral number if applicable',

    -- Source metadata (DCA SCD2 pattern)
    _SOURCE_SYSTEM          VARCHAR(50)     NOT NULL DEFAULT 'EPIC_CLARITY'  COMMENT 'Source system name',
    _LOADED_AT              TIMESTAMP_NTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP()  COMMENT 'ETL load timestamp',
    _RECORD_HASH            VARCHAR(64)                 COMMENT 'SHA-256 hash for change detection',

    CONSTRAINT PK_RAW_CLAIMS PRIMARY KEY (CLAIM_ID, CLAIM_LINE_NUMBER)
)
CLUSTER BY (SERVICE_DATE, MEMBER_ID)
COMMENT = 'Raw adjudicated claim lines from Epic Clarity / 835 EDI. Source of truth for SLA tracking and risk adjustment.';

-- Apply governance tags
ALTER TABLE RAW_DEV.SUTTER_HEALTH.RAW_CLAIMS
    SET TAG RAW_DEV.SUTTER_HEALTH.PHI_CLASSIFICATION = 'PHI',
            RAW_DEV.SUTTER_HEALTH.SLA_TIER = 'CRITICAL_24HR',
            RAW_DEV.SUTTER_HEALTH.RISK_DOMAIN = 'CLAIMS_ADJUDICATION';

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. MEMBER_ENROLLMENT — Plan membership and risk scores
--    Source: Eligibility 834 EDI transactions
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS RAW_DEV.SUTTER_HEALTH.MEMBER_ENROLLMENT (
    -- Identifiers
    MEMBER_ID               VARCHAR(36)     NOT NULL    COMMENT 'Unique member identifier (UUID)',
    SUBSCRIBER_ID           VARCHAR(20)     NOT NULL    COMMENT 'Group/subscriber ID',
    MBI_NUMBER              VARCHAR(11)                 COMMENT 'Medicare Beneficiary Identifier (Medicare Advantage)',
    MEDICAID_ID             VARCHAR(20)                 COMMENT 'State Medicaid ID',
    MEMBER_RELATIONSHIP     VARCHAR(20)     NOT NULL    COMMENT 'SELF, SPOUSE, DEPENDENT',

    -- Plan
    PLAN_ID                 VARCHAR(20)     NOT NULL    COMMENT 'Internal plan code',
    PLAN_NAME               VARCHAR(100)                COMMENT 'Plan display name',
    PLAN_TYPE               VARCHAR(30)     NOT NULL    COMMENT 'HMO, PPO, POS, HDHP, MEDICARE_ADVANTAGE, MEDICAID_MANAGED',
    PRODUCT_LINE            VARCHAR(30)                 COMMENT 'COMMERCIAL, MEDICARE, MEDICAID, EXCHANGE',
    GROUP_NUMBER            VARCHAR(20)                 COMMENT 'Employer group number',
    EMPLOYER_NAME           VARCHAR(100)                COMMENT 'Employer / group name',

    -- Demographics
    DATE_OF_BIRTH           DATE            NOT NULL    COMMENT 'Member date of birth',
    GENDER                  VARCHAR(1)      NOT NULL    COMMENT 'M, F, U',
    ZIP_CODE                VARCHAR(10)     NOT NULL    COMMENT 'Member residential ZIP code',
    COUNTY_CODE             VARCHAR(5)                  COMMENT 'FIPS county code',
    STATE_CODE              VARCHAR(2)                  COMMENT 'State abbreviation',

    -- Enrollment
    COVERAGE_START_DATE     DATE            NOT NULL    COMMENT 'Coverage effective date',
    COVERAGE_END_DATE       DATE                        COMMENT 'Coverage termination date (NULL if active)',
    ENROLLMENT_STATUS       VARCHAR(20)     NOT NULL    COMMENT 'ACTIVE, TERMED, COBRA, PENDING, SUSPENDED',
    COBRA_FLAG              BOOLEAN         NOT NULL DEFAULT FALSE  COMMENT 'Member on COBRA continuation',
    DUAL_ELIGIBLE           BOOLEAN         NOT NULL DEFAULT FALSE  COMMENT 'Medicare/Medicaid dual eligible',
    LIS_LEVEL               VARCHAR(10)                 COMMENT 'Low Income Subsidy level (Medicare Part D)',

    -- Risk adjustment — key demo columns
    RISK_SCORE              DECIMAL(6,4)    NOT NULL DEFAULT 1.0  COMMENT 'CMS-HCC composite risk score',
    PRIOR_YEAR_RISK_SCORE   DECIMAL(6,4)                COMMENT 'Prior plan year risk score for YoY comparison',
    RISK_CATEGORY           VARCHAR(30)     NOT NULL    COMMENT 'LOW, MODERATE, HIGH, VERY_HIGH, CATASTROPHIC',
    RISK_PERCENTILE         INTEGER                     COMMENT 'Member risk percentile within plan (1-100)',
    PROSPECTIVE_RISK_SCORE  DECIMAL(6,4)                COMMENT 'Forward-looking risk score from predictive model',

    -- Care management
    CARE_MANAGEMENT_FLAG    BOOLEAN         NOT NULL DEFAULT FALSE  COMMENT 'Enrolled in care management program',
    CHRONIC_CONDITION_COUNT INTEGER         NOT NULL DEFAULT 0  COMMENT 'Number of documented chronic conditions',
    PRIMARY_CARE_NPI        VARCHAR(10)                 COMMENT 'Assigned PCP NPI',

    -- Source metadata
    _SOURCE_SYSTEM          VARCHAR(50)     NOT NULL DEFAULT 'ELIGIBILITY_834'  COMMENT 'Source system name',
    _VALID_FROM             TIMESTAMP_NTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP()  COMMENT 'SCD2 valid from',
    _VALID_TO               TIMESTAMP_NTZ               COMMENT 'SCD2 valid to (NULL = current record)',
    _IS_CURRENT             BOOLEAN         NOT NULL DEFAULT TRUE  COMMENT 'SCD2 current record flag',
    _LOADED_AT              TIMESTAMP_NTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP()  COMMENT 'ETL load timestamp',
    _RECORD_HASH            VARCHAR(64)                 COMMENT 'SHA-256 hash for change detection',

    CONSTRAINT PK_MEMBER_ENROLLMENT PRIMARY KEY (MEMBER_ID, _VALID_FROM)
)
COMMENT = 'Plan member enrollment and risk score data (SCD Type 2). Source: 834 EDI + CMS risk model outputs.';

ALTER TABLE RAW_DEV.SUTTER_HEALTH.MEMBER_ENROLLMENT
    SET TAG RAW_DEV.SUTTER_HEALTH.PHI_CLASSIFICATION = 'PHI',
            RAW_DEV.SUTTER_HEALTH.RISK_DOMAIN = 'MEMBER_MGMT';

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. PROVIDER_DIRECTORY — Credentialed providers and network status
--    Source: CAQH ProView + internal credentialing system
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS RAW_DEV.SUTTER_HEALTH.PROVIDER_DIRECTORY (
    -- Identifiers
    PROVIDER_NPI            VARCHAR(10)     NOT NULL    COMMENT 'National Provider Identifier (Type 1)',
    GROUP_NPI               VARCHAR(10)                 COMMENT 'Group/organizational NPI (Type 2)',
    TIN                     VARCHAR(10)                 COMMENT 'Tax Identification Number (masked in non-admin roles)',
    PROVIDER_LAST_NAME      VARCHAR(100)    NOT NULL    COMMENT 'Provider last name / organization name',
    PROVIDER_FIRST_NAME     VARCHAR(50)                 COMMENT 'Provider first name',
    PROVIDER_CREDENTIAL     VARCHAR(30)                 COMMENT 'MD, DO, NP, PA, DDS, PhD, etc.',

    -- Specialty
    SPECIALTY_CODE          VARCHAR(10)                 COMMENT 'CMS provider specialty code',
    SPECIALTY_DESC          VARCHAR(100)                COMMENT 'Specialty description',
    TAXONOMY_CODE           VARCHAR(10)                 COMMENT 'NUCC Health Care Provider Taxonomy code',
    PRIMARY_CARE_FLAG       BOOLEAN         NOT NULL DEFAULT FALSE  COMMENT 'TRUE if PCP / primary care provider',

    -- Network
    NETWORK_STATUS          VARCHAR(20)     NOT NULL    COMMENT 'IN_NETWORK, OUT_OF_NETWORK, PREFERRED, TERMINATED',
    NETWORK_EFFECTIVE_DATE  DATE                        COMMENT 'Date provider joined network',
    NETWORK_TERM_DATE       DATE                        COMMENT 'Network termination date (NULL if active)',
    ACCEPTING_NEW_PATIENTS  BOOLEAN         NOT NULL DEFAULT TRUE  COMMENT 'Currently accepting new patients',
    TELEHEALTH_ENABLED      BOOLEAN         NOT NULL DEFAULT FALSE  COMMENT 'Offers telehealth services',
    QUALITY_TIER            VARCHAR(10)                 COMMENT 'TIER_1 (preferred), TIER_2, TIER_3',

    -- Practice location (primary)
    PRACTICE_ADDRESS_LINE1  VARCHAR(200)                COMMENT 'Practice street address',
    PRACTICE_CITY           VARCHAR(100)                COMMENT 'Practice city',
    PRACTICE_STATE          VARCHAR(2)                  COMMENT 'Practice state',
    PRACTICE_ZIP            VARCHAR(10)                 COMMENT 'Practice ZIP code',
    PRACTICE_COUNTY_CODE    VARCHAR(5)                  COMMENT 'FIPS county code',
    PRACTICE_LATITUDE       DECIMAL(10,7)               COMMENT 'Geocoded latitude',
    PRACTICE_LONGITUDE      DECIMAL(10,7)               COMMENT 'Geocoded longitude',
    PRACTICE_PHONE          VARCHAR(15)                 COMMENT 'Practice phone number',

    -- Credentialing
    CREDENTIAL_STATUS       VARCHAR(20)                 COMMENT 'ACTIVE, PENDING, SUSPENDED, EXPIRED',
    CREDENTIAL_EXPIRY_DATE  DATE                        COMMENT 'Credentialing expiration date',
    BOARD_CERTIFIED         BOOLEAN         NOT NULL DEFAULT FALSE  COMMENT 'Board certification status',
    MALPRACTICE_FLAG        BOOLEAN         NOT NULL DEFAULT FALSE  COMMENT 'Active malpractice action on file',

    -- Volume metrics (updated by risk adjustment pipeline)
    CLAIM_VOLUME_30D        INTEGER                     COMMENT 'Claims in last 30 days',
    RISK_FLAG_VOLUME_30D    INTEGER                     COMMENT 'HCC flags generated in last 30 days',
    AVG_RISK_SCORE_PANEL    DECIMAL(6,4)                COMMENT 'Average risk score across attributed panel',

    -- Source metadata
    _SOURCE_SYSTEM          VARCHAR(50)     NOT NULL DEFAULT 'CAQH_PROVIEW'  COMMENT 'Source system name',
    _LOADED_AT              TIMESTAMP_NTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP()  COMMENT 'ETL load timestamp',
    _RECORD_HASH            VARCHAR(64)                 COMMENT 'SHA-256 hash for change detection',

    CONSTRAINT PK_PROVIDER_DIRECTORY PRIMARY KEY (PROVIDER_NPI)
)
COMMENT = 'Provider directory with network status and credentialing. Updated weekly from CAQH ProView.';

ALTER TABLE RAW_DEV.SUTTER_HEALTH.PROVIDER_DIRECTORY
    SET TAG RAW_DEV.SUTTER_HEALTH.PHI_CLASSIFICATION = 'DE_IDENTIFIED',
            RAW_DEV.SUTTER_HEALTH.RISK_DOMAIN = 'PROVIDER_CREDENTIALING';

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. RISK_ADJUSTMENT_FLAGS — HCC flags from daily risk adjustment pipeline
--    Written by: SP_SH_RISK_ADJUSTMENT_DAILY_RUN
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS RAW_DEV.SUTTER_HEALTH.RISK_ADJUSTMENT_FLAGS (
    -- Identifiers
    FLAG_ID                 VARCHAR(36)     NOT NULL    COMMENT 'Unique flag identifier (UUID)',
    MEMBER_ID               VARCHAR(36)     NOT NULL    COMMENT 'FK → MEMBER_ENROLLMENT.MEMBER_ID',
    CLAIM_ID                VARCHAR(36)                 COMMENT 'FK → RAW_CLAIMS.CLAIM_ID (source claim)',

    -- HCC mapping
    HCC_CODE                VARCHAR(10)     NOT NULL    COMMENT 'CMS-HCC category code (e.g. HCC19, HCC86)',
    HCC_DESCRIPTION         VARCHAR(200)                COMMENT 'HCC category description',
    ICD10_CODE              VARCHAR(10)     NOT NULL    COMMENT 'ICD-10-CM code that triggered the flag',
    ICD10_DESCRIPTION       VARCHAR(200)                COMMENT 'ICD-10 description',

    -- Risk weights
    RISK_WEIGHT             DECIMAL(6,4)    NOT NULL    COMMENT 'CMS-HCC risk weight for this category',
    RISK_COEFFICIENT        DECIMAL(6,4)                COMMENT 'Age/sex coefficient applied',
    INCREMENTAL_RISK        DECIMAL(6,4)                COMMENT 'Incremental risk contribution to member total',

    -- Flag metadata
    FLAG_DATE               DATE            NOT NULL    COMMENT 'Date HCC flag was generated',
    FLAG_SOURCE             VARCHAR(20)     NOT NULL    COMMENT 'CLAIMS, ENCOUNTER, CHART_REVIEW, PROSPECTIVE',
    FLAG_STATUS             VARCHAR(20)     NOT NULL    COMMENT 'ACTIVE, VALIDATED, DELETED, SUPERSEDED',
    VALIDATION_SOURCE       VARCHAR(50)                 COMMENT 'Clinical validation source if applicable',
    PLAN_YEAR               INTEGER         NOT NULL    COMMENT 'Benefit plan year this flag applies to',

    -- SLA breach association
    CLAIM_SLA_MET           BOOLEAN                     COMMENT 'Was the source claim processed within SLA?',
    CLAIM_PROCESSING_HOURS  DECIMAL(8,2)                COMMENT 'Hours to process the source claim',

    -- Pipeline run reference
    PIPELINE_RUN_ID         VARCHAR(36)                 COMMENT 'FK → RISK_ADJUSTMENT_DAILY_RUN.RUN_ID',
    RUN_DATE                DATE            NOT NULL    COMMENT 'Date the pipeline run that generated this flag',

    -- Source metadata
    _SOURCE_SYSTEM          VARCHAR(50)     NOT NULL DEFAULT 'RISK_ADJ_PIPELINE'  COMMENT 'Source system name',
    _LOADED_AT              TIMESTAMP_NTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP()  COMMENT 'ETL load timestamp',

    CONSTRAINT PK_RISK_ADJUSTMENT_FLAGS PRIMARY KEY (FLAG_ID)
)
CLUSTER BY (FLAG_DATE, MEMBER_ID)
COMMENT = 'CMS-HCC risk adjustment flags. Written by the daily SP_SH_RISK_ADJUSTMENT_DAILY_RUN stored procedure.';

ALTER TABLE RAW_DEV.SUTTER_HEALTH.RISK_ADJUSTMENT_FLAGS
    SET TAG RAW_DEV.SUTTER_HEALTH.PHI_CLASSIFICATION = 'PHI',
            RAW_DEV.SUTTER_HEALTH.RISK_DOMAIN = 'HCC_RISK';

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. CLAIMS_SUMMARY — Member-level rollup (updated by pipeline)
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS RAW_DEV.SUTTER_HEALTH.CLAIMS_SUMMARY (
    SUMMARY_ID              VARCHAR(36)     NOT NULL    COMMENT 'Unique summary record ID (UUID)',
    MEMBER_ID               VARCHAR(36)     NOT NULL    COMMENT 'FK → MEMBER_ENROLLMENT.MEMBER_ID',
    PLAN_YEAR               INTEGER         NOT NULL    COMMENT 'Benefit plan year',

    -- Claim volume
    TOTAL_CLAIMS            INTEGER         NOT NULL DEFAULT 0  COMMENT 'Total claim count (all statuses)',
    PAID_CLAIMS             INTEGER         NOT NULL DEFAULT 0  COMMENT 'Number of paid/adjudicated claims',
    DENIED_CLAIMS           INTEGER         NOT NULL DEFAULT 0  COMMENT 'Number of denied claims',
    PENDING_CLAIMS          INTEGER         NOT NULL DEFAULT 0  COMMENT 'Claims awaiting adjudication',
    UNIQUE_PROVIDERS        INTEGER                     COMMENT 'Distinct provider NPIs billed',
    UNIQUE_CLAIM_TYPES      INTEGER                     COMMENT 'Distinct claim types submitted',

    -- Financial
    TOTAL_BILLED_AMOUNT     DECIMAL(14,2)   NOT NULL DEFAULT 0  COMMENT 'Sum of billed charges',
    TOTAL_ALLOWED_AMOUNT    DECIMAL(14,2)               COMMENT 'Sum of allowed amounts',
    TOTAL_PAID_AMOUNT       DECIMAL(14,2)               COMMENT 'Sum of paid amounts',
    TOTAL_MEMBER_RESP       DECIMAL(14,2)               COMMENT 'Sum of member responsibility',
    DENIAL_RATE             DECIMAL(5,4)                COMMENT 'Denied / total claims ratio',

    -- SLA metrics — key demo columns
    SLA_BREACH_COUNT        INTEGER         NOT NULL DEFAULT 0  COMMENT 'Number of claims that missed 24hr SLA',
    SLA_MET_COUNT           INTEGER         NOT NULL DEFAULT 0  COMMENT 'Number of claims meeting SLA',
    SLA_BREACH_RATE         DECIMAL(5,4)                COMMENT 'SLA breach / total claims ratio',
    AVG_PROCESSING_HOURS    DECIMAL(8,2)                COMMENT 'Average claim-to-payment processing hours',
    MAX_PROCESSING_HOURS    DECIMAL(8,2)                COMMENT 'Worst-case processing time in hours',
    P90_PROCESSING_HOURS    DECIMAL(8,2)                COMMENT '90th percentile processing hours',

    -- Risk
    RISK_SCORE              DECIMAL(6,4)                COMMENT 'Current CMS-HCC risk score',
    PRIMARY_RISK_CATEGORY   VARCHAR(30)                 COMMENT 'Dominant risk category: LOW/MODERATE/HIGH/VERY_HIGH',
    ACTIVE_HCC_COUNT        INTEGER                     COMMENT 'Number of active HCC flags',
    CHRONIC_CONDITION_COUNT INTEGER                     COMMENT 'Documented chronic conditions',

    -- Timeline
    FIRST_SERVICE_DATE      DATE                        COMMENT 'Earliest service date in period',
    LAST_SERVICE_DATE       DATE                        COMMENT 'Most recent service date in period',
    LAST_UPDATED_TS         TIMESTAMP_NTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP()  COMMENT 'Last pipeline update timestamp',

    -- Source metadata
    _SOURCE_SYSTEM          VARCHAR(50)     NOT NULL DEFAULT 'RISK_ADJ_PIPELINE'  COMMENT 'Source system name',
    _LOADED_AT              TIMESTAMP_NTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP()  COMMENT 'ETL load timestamp',

    CONSTRAINT PK_CLAIMS_SUMMARY PRIMARY KEY (SUMMARY_ID),
    CONSTRAINT UQ_CLAIMS_SUMMARY_MEMBER_YEAR UNIQUE (MEMBER_ID, PLAN_YEAR)
)
COMMENT = 'Member-level claims summary with SLA metrics and risk scores. Refreshed by daily risk adjustment pipeline.';

ALTER TABLE RAW_DEV.SUTTER_HEALTH.CLAIMS_SUMMARY
    SET TAG RAW_DEV.SUTTER_HEALTH.PHI_CLASSIFICATION = 'PHI',
            RAW_DEV.SUTTER_HEALTH.SLA_TIER = 'CRITICAL_24HR',
            RAW_DEV.SUTTER_HEALTH.RISK_DOMAIN = 'HCC_RISK';

-- ═══════════════════════════════════════════════════════════════════════════
-- Validation
-- ═══════════════════════════════════════════════════════════════════════════

SELECT
    TABLE_NAME,
    COLUMN_COUNT,
    COMMENT
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'SUTTER_HEALTH'
  AND TABLE_CATALOG = 'RAW_DEV'
ORDER BY TABLE_NAME;
