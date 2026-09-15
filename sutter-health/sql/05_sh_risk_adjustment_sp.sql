-- ============================================================================
-- SUTTER HEALTH DEMO — Risk Adjustment Pipeline: Daily Stored Procedure
-- ============================================================================
--
-- SP_SH_RISK_ADJUSTMENT_DAILY_RUN
--   Simulates the daily risk adjustment registry run that health plans submit
--   to CMS for reimbursement rate calibration.
--
-- What it does:
--   1. Reads RAW_CLAIMS for the specified run_date window
--   2. Joins to MEMBER_ENROLLMENT to get current risk scores and demographics
--   3. Maps primary ICD-10 codes to CMS-HCC categories
--   4. Flags claims that missed the 24-hour adjudication SLA
--   5. Writes new records to RISK_ADJUSTMENT_DAILY_RUN (append-only audit log)
--   6. Updates CLAIMS_SUMMARY member rollups
--   7. Returns a VARIANT with run stats: rows processed, SLA breaches, runtime
--
-- DEMO TALKING POINT:
--   "What Milliman does manually in 3-5 business days, Snowflake runs in
--    under 10 seconds on an XS warehouse — with a full audit log and
--    near-real-time member risk score updates."
--
-- Run cost: ~$0.045 at $2.50/credit for XS (2 credits/hr × ~$0.009/min × 1 min)
--
-- Prerequisites: 04_sh_curated_layer.sql, data loaded via 03_sh_load_data.sql
-- RUN AS: DATA_ADMIN
-- ============================================================================

USE ROLE DATA_ADMIN;
USE DATABASE RAW_DEV;
USE SCHEMA SUTTER_HEALTH;

-- ═══════════════════════════════════════════════════════════════════════════
-- RISK_ADJUSTMENT_DAILY_RUN — Append-only audit log of pipeline executions
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS RAW_DEV.SUTTER_HEALTH.RISK_ADJUSTMENT_DAILY_RUN (
    RUN_ID                  VARCHAR(36)     NOT NULL    COMMENT 'Unique pipeline run ID (UUID)',
    RUN_DATE                DATE            NOT NULL    COMMENT 'Date the pipeline ran',
    RUN_START_TS            TIMESTAMP_NTZ   NOT NULL    COMMENT 'Pipeline start timestamp',
    RUN_END_TS              TIMESTAMP_NTZ               COMMENT 'Pipeline completion timestamp',
    RUNTIME_SECONDS         DECIMAL(10,3)               COMMENT 'Wall-clock execution time in seconds',

    -- Processing summary
    CLAIMS_EVALUATED        INTEGER         NOT NULL DEFAULT 0  COMMENT 'Total claim lines evaluated',
    MEMBERS_PROCESSED       INTEGER         NOT NULL DEFAULT 0  COMMENT 'Distinct members with claims',
    HCC_FLAGS_WRITTEN       INTEGER         NOT NULL DEFAULT 0  COMMENT 'New HCC flags inserted',
    HCC_FLAGS_UPDATED       INTEGER         NOT NULL DEFAULT 0  COMMENT 'Existing HCC flags updated',
    SUMMARY_ROWS_UPDATED    INTEGER         NOT NULL DEFAULT 0  COMMENT 'CLAIMS_SUMMARY rows updated',

    -- SLA metrics
    SLA_BREACHES_DETECTED   INTEGER         NOT NULL DEFAULT 0  COMMENT 'Claims missing 24hr SLA',
    SLA_COMPLIANCE_RATE     DECIMAL(5,4)                COMMENT 'Fraction of claims meeting SLA',
    AVG_PROCESSING_HOURS    DECIMAL(8,2)                COMMENT 'Average adjudication time hours',
    MAX_PROCESSING_HOURS    DECIMAL(8,2)                COMMENT 'Worst-case adjudication time hours',

    -- Risk summary
    HIGH_RISK_MEMBERS       INTEGER                     COMMENT 'Members with risk_score >= 2.0',
    VERY_HIGH_RISK_MEMBERS  INTEGER                     COMMENT 'Members with risk_score >= 3.0',
    AVG_RISK_SCORE_RUN      DECIMAL(6,4)                COMMENT 'Average risk score across run population',

    -- Pipeline status
    RUN_STATUS              VARCHAR(20)     NOT NULL    COMMENT 'RUNNING, COMPLETED, FAILED',
    ERROR_MESSAGE           VARCHAR(500)                COMMENT 'Error detail if status = FAILED',
    WAREHOUSE_USED          VARCHAR(50)                 COMMENT 'Warehouse that executed the run',

    CONSTRAINT PK_RISK_ADJ_DAILY_RUN PRIMARY KEY (RUN_ID)
)
COMMENT = 'Append-only audit log for SP_SH_RISK_ADJUSTMENT_DAILY_RUN executions. One row per daily pipeline run.';

-- ═══════════════════════════════════════════════════════════════════════════
-- HCC Mapping Reference (inline with SP for portability)
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS RAW_DEV.SUTTER_HEALTH.HCC_ICD10_MAPPING (
    ICD10_PREFIX            VARCHAR(10)     NOT NULL    COMMENT 'ICD-10 code prefix to match (LIKE pattern)',
    HCC_CODE                VARCHAR(10)     NOT NULL    COMMENT 'CMS-HCC category code',
    HCC_DESCRIPTION         VARCHAR(200)    NOT NULL    COMMENT 'HCC category description',
    RISK_WEIGHT             DECIMAL(6,4)    NOT NULL    COMMENT 'CMS-published risk weight for 2024',
    CLINICAL_CATEGORY       VARCHAR(30)     NOT NULL    COMMENT 'Broad clinical grouping',
    CONSTRAINT PK_HCC_MAPPING PRIMARY KEY (ICD10_PREFIX)
);

-- Seed the HCC mapping table (representative subset for demo)
INSERT INTO RAW_DEV.SUTTER_HEALTH.HCC_ICD10_MAPPING VALUES
-- Diabetes
('E10',  'HCC17', 'Diabetes with Acute Complications',          0.368, 'DIABETES'),
('E11',  'HCC19', 'Diabetes without Complication',              0.118, 'DIABETES'),
('E13',  'HCC18', 'Diabetes with Chronic Complications',        0.302, 'DIABETES'),
-- Cardiac / CHF
('I21',  'HCC86', 'Acute Myocardial Infarction',                0.365, 'CARDIAC'),
('I50',  'HCC85', 'Congestive Heart Failure',                   0.331, 'CARDIAC'),
('I48',  'HCC96', 'Specified Heart Arrhythmias',                0.271, 'CARDIAC'),
('I25',  'HCC88', 'Angina Pectoris / Old MI',                   0.241, 'CARDIAC'),
-- Respiratory
('J44',  'HCC111','COPD',                                       0.335, 'RESPIRATORY'),
('J43',  'HCC112','Fibrosis/Pneumoconiosis',                    0.199, 'RESPIRATORY'),
('J45',  'HCC110','Chronic Obstructive Pulmonary Disease',      0.335, 'RESPIRATORY'),
-- Renal
('N18',  'HCC136','Chronic Kidney Disease Stage 4',             0.237, 'RENAL'),
('N17',  'HCC135','Acute Renal Failure',                        0.441, 'RENAL'),
-- Oncology
('C34',  'HCC9',  'Lung and Other Severe Cancers',              2.422, 'ONCOLOGY'),
('C50',  'HCC12', 'Breast, Prostate, Colorectal Cancers',       0.664, 'ONCOLOGY'),
('C18',  'HCC12', 'Colon Cancer',                               0.664, 'ONCOLOGY'),
-- Behavioral Health
('F20',  'HCC57', 'Schizophrenia',                              0.620, 'BEHAVIORAL_HEALTH'),
('F31',  'HCC58', 'Major Depressive, Bipolar Disorders',        0.395, 'BEHAVIORAL_HEALTH'),
('F32',  'HCC59', 'Reactive and Unspecified Psychosis',         0.395, 'BEHAVIORAL_HEALTH'),
-- Musculoskeletal
('M80',  'HCC168','Hip Fracture/Dislocation',                   0.489, 'MUSCULOSKELETAL'),
('M16',  'HCC40', 'Rheumatoid Arthritis',                       0.421, 'MUSCULOSKELETAL')
;

-- ═══════════════════════════════════════════════════════════════════════════
-- STORED PROCEDURE — Daily Risk Adjustment Pipeline
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE PROCEDURE RAW_DEV.SUTTER_HEALTH.SP_SH_RISK_ADJUSTMENT_DAILY_RUN(
    RUN_DATE_PARAM DATE,
    LOOKBACK_DAYS  INTEGER DEFAULT 30
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
COMMENT = 'Daily risk adjustment pipeline. Reads raw_claims, maps ICD-10→HCC, flags SLA breaches, writes audit log.'
AS
$$
DECLARE
    v_run_id            VARCHAR;
    v_start_ts          TIMESTAMP_NTZ;
    v_end_ts            TIMESTAMP_NTZ;
    v_runtime_sec       DECIMAL(10,3);
    v_claims_evaluated  INTEGER DEFAULT 0;
    v_members_processed INTEGER DEFAULT 0;
    v_hcc_flags_written INTEGER DEFAULT 0;
    v_sla_breaches      INTEGER DEFAULT 0;
    v_summary_updated   INTEGER DEFAULT 0;
    v_high_risk         INTEGER DEFAULT 0;
    v_very_high_risk    INTEGER DEFAULT 0;
    v_avg_risk          DECIMAL(6,4) DEFAULT 0.0;
    v_avg_proc_hrs      DECIMAL(8,2) DEFAULT 0.0;
    v_max_proc_hrs      DECIMAL(8,2) DEFAULT 0.0;
    v_sla_rate          DECIMAL(5,4) DEFAULT 0.0;
    v_result            VARIANT;
BEGIN
    -- ── Step 0: Initialize run metadata ──────────────────────────────────
    v_run_id   := UUID_STRING();
    v_start_ts := CURRENT_TIMESTAMP();

    -- Log run start
    INSERT INTO RAW_DEV.SUTTER_HEALTH.RISK_ADJUSTMENT_DAILY_RUN (
        RUN_ID, RUN_DATE, RUN_START_TS, RUN_STATUS, WAREHOUSE_USED
    ) VALUES (
        :v_run_id, :RUN_DATE_PARAM, :v_start_ts, 'RUNNING',
        CURRENT_WAREHOUSE()
    );

    -- ── Step 1: Count claims in window ────────────────────────────────────
    SELECT COUNT(*), COUNT(DISTINCT MEMBER_ID)
    INTO :v_claims_evaluated, :v_members_processed
    FROM RAW_DEV.SUTTER_HEALTH.RAW_CLAIMS
    WHERE SERVICE_DATE BETWEEN DATEADD('day', -:LOOKBACK_DAYS, :RUN_DATE_PARAM)
                           AND :RUN_DATE_PARAM;

    -- ── Step 2: Compute SLA metrics ───────────────────────────────────────
    SELECT
        COUNT(CASE WHEN SLA_MET = FALSE THEN 1 END),
        AVG(PROCESSING_HOURS),
        MAX(PROCESSING_HOURS),
        AVG(CASE WHEN SLA_MET = TRUE THEN 1.0 ELSE 0.0 END)
    INTO
        :v_sla_breaches,
        :v_avg_proc_hrs,
        :v_max_proc_hrs,
        :v_sla_rate
    FROM RAW_DEV.SUTTER_HEALTH.RAW_CLAIMS
    WHERE SERVICE_DATE BETWEEN DATEADD('day', -:LOOKBACK_DAYS, :RUN_DATE_PARAM)
                           AND :RUN_DATE_PARAM
      AND CLAIM_PROCESSED_TS IS NOT NULL;

    -- ── Step 3: Insert new HCC flags ──────────────────────────────────────
    INSERT INTO RAW_DEV.SUTTER_HEALTH.RISK_ADJUSTMENT_FLAGS (
        FLAG_ID, MEMBER_ID, CLAIM_ID,
        HCC_CODE, HCC_DESCRIPTION, ICD10_CODE, ICD10_DESCRIPTION,
        RISK_WEIGHT, RISK_COEFFICIENT, INCREMENTAL_RISK,
        FLAG_DATE, FLAG_SOURCE, FLAG_STATUS, PLAN_YEAR,
        CLAIM_SLA_MET, CLAIM_PROCESSING_HOURS,
        PIPELINE_RUN_ID, RUN_DATE,
        _SOURCE_SYSTEM, _LOADED_AT
    )
    SELECT
        UUID_STRING()                           AS FLAG_ID,
        c.MEMBER_ID,
        c.CLAIM_ID,
        m.HCC_CODE,
        m.HCC_DESCRIPTION,
        c.PRIMARY_DX_CODE,
        m.HCC_DESCRIPTION                       AS ICD10_DESCRIPTION,
        m.RISK_WEIGHT,
        -- Age/sex coefficient: simplified (1.0 base + small gender delta)
        CASE e.GENDER WHEN 'M' THEN 1.02 ELSE 1.00 END AS RISK_COEFFICIENT,
        m.RISK_WEIGHT * CASE e.GENDER WHEN 'M' THEN 1.02 ELSE 1.00 END AS INCREMENTAL_RISK,
        :RUN_DATE_PARAM                         AS FLAG_DATE,
        'CLAIMS'                                AS FLAG_SOURCE,
        'ACTIVE'                                AS FLAG_STATUS,
        c.PLAN_YEAR,
        c.SLA_MET                               AS CLAIM_SLA_MET,
        c.PROCESSING_HOURS                      AS CLAIM_PROCESSING_HOURS,
        :v_run_id                               AS PIPELINE_RUN_ID,
        :RUN_DATE_PARAM                         AS RUN_DATE,
        'RISK_ADJ_PIPELINE'                     AS _SOURCE_SYSTEM,
        CURRENT_TIMESTAMP()                     AS _LOADED_AT
    FROM RAW_DEV.SUTTER_HEALTH.RAW_CLAIMS c
    -- Match ICD-10 prefix to HCC mapping
    JOIN RAW_DEV.SUTTER_HEALTH.HCC_ICD10_MAPPING m
        ON c.PRIMARY_DX_CODE LIKE m.ICD10_PREFIX || '%'
    -- Get member demographics for coefficient
    JOIN RAW_DEV.SUTTER_HEALTH.MEMBER_ENROLLMENT e
        ON c.MEMBER_ID = e.MEMBER_ID
       AND e._IS_CURRENT = TRUE
    -- Only include claims in the lookback window
    WHERE c.SERVICE_DATE BETWEEN DATEADD('day', -:LOOKBACK_DAYS, :RUN_DATE_PARAM)
                              AND :RUN_DATE_PARAM
      AND c.CLAIM_STATUS = 'PAID'
      -- Avoid duplicates: only insert flags not already generated by this run
      AND NOT EXISTS (
          SELECT 1 FROM RAW_DEV.SUTTER_HEALTH.RISK_ADJUSTMENT_FLAGS f
          WHERE f.MEMBER_ID = c.MEMBER_ID
            AND f.ICD10_CODE = c.PRIMARY_DX_CODE
            AND f.HCC_CODE = m.HCC_CODE
            AND f.PLAN_YEAR = c.PLAN_YEAR
            AND f.PIPELINE_RUN_ID = :v_run_id
      );

    v_hcc_flags_written := SQLROWCOUNT;

    -- ── Step 4: Upsert CLAIMS_SUMMARY ────────────────────────────────────
    MERGE INTO RAW_DEV.SUTTER_HEALTH.CLAIMS_SUMMARY AS tgt
    USING (
        SELECT
            e.MEMBER_ID,
            c.PLAN_YEAR,
            COUNT(*)                                        AS TOTAL_CLAIMS,
            COUNT(CASE WHEN c.CLAIM_STATUS = 'PAID'    THEN 1 END) AS PAID_CLAIMS,
            COUNT(CASE WHEN c.CLAIM_STATUS = 'DENIED'  THEN 1 END) AS DENIED_CLAIMS,
            COUNT(CASE WHEN c.CLAIM_STATUS = 'PENDING' THEN 1 END) AS PENDING_CLAIMS,
            COUNT(DISTINCT c.PROVIDER_NPI)                  AS UNIQUE_PROVIDERS,
            COUNT(DISTINCT c.CLAIM_TYPE)                    AS UNIQUE_CLAIM_TYPES,
            SUM(c.BILLED_AMOUNT)                            AS TOTAL_BILLED_AMOUNT,
            SUM(c.ALLOWED_AMOUNT)                           AS TOTAL_ALLOWED_AMOUNT,
            SUM(c.PAID_AMOUNT)                              AS TOTAL_PAID_AMOUNT,
            SUM(c.MEMBER_RESPONSIBILITY)                    AS TOTAL_MEMBER_RESP,
            ZEROIFNULL(
              COUNT(CASE WHEN c.CLAIM_STATUS = 'DENIED' THEN 1 END)::DECIMAL /
              NULLIF(COUNT(*), 0))                          AS DENIAL_RATE,
            COUNT(CASE WHEN c.SLA_MET = FALSE           THEN 1 END) AS SLA_BREACH_COUNT,
            COUNT(CASE WHEN c.SLA_MET = TRUE            THEN 1 END) AS SLA_MET_COUNT,
            ZEROIFNULL(
              COUNT(CASE WHEN c.SLA_MET = FALSE THEN 1 END)::DECIMAL /
              NULLIF(COUNT(CASE WHEN c.CLAIM_PROCESSED_TS IS NOT NULL THEN 1 END),0))
                                                            AS SLA_BREACH_RATE,
            AVG(c.PROCESSING_HOURS)                         AS AVG_PROCESSING_HOURS,
            MAX(c.PROCESSING_HOURS)                         AS MAX_PROCESSING_HOURS,
            PERCENTILE_CONT(0.9) WITHIN GROUP
                (ORDER BY c.PROCESSING_HOURS)               AS P90_PROCESSING_HOURS,
            e.RISK_SCORE,
            e.RISK_CATEGORY                                 AS PRIMARY_RISK_CATEGORY,
            e.CHRONIC_CONDITION_COUNT,
            MIN(c.SERVICE_DATE)                             AS FIRST_SERVICE_DATE,
            MAX(c.SERVICE_DATE)                             AS LAST_SERVICE_DATE
        FROM RAW_DEV.SUTTER_HEALTH.RAW_CLAIMS c
        JOIN RAW_DEV.SUTTER_HEALTH.MEMBER_ENROLLMENT e
            ON c.MEMBER_ID = e.MEMBER_ID
           AND e._IS_CURRENT = TRUE
        WHERE c.SERVICE_DATE BETWEEN DATEADD('day', -365, :RUN_DATE_PARAM)
                                 AND :RUN_DATE_PARAM
        GROUP BY e.MEMBER_ID, c.PLAN_YEAR, e.RISK_SCORE, e.RISK_CATEGORY, e.CHRONIC_CONDITION_COUNT
    ) AS src
    ON tgt.MEMBER_ID = src.MEMBER_ID AND tgt.PLAN_YEAR = src.PLAN_YEAR
    WHEN MATCHED THEN UPDATE SET
        TOTAL_CLAIMS          = src.TOTAL_CLAIMS,
        PAID_CLAIMS           = src.PAID_CLAIMS,
        DENIED_CLAIMS         = src.DENIED_CLAIMS,
        PENDING_CLAIMS        = src.PENDING_CLAIMS,
        UNIQUE_PROVIDERS      = src.UNIQUE_PROVIDERS,
        UNIQUE_CLAIM_TYPES    = src.UNIQUE_CLAIM_TYPES,
        TOTAL_BILLED_AMOUNT   = src.TOTAL_BILLED_AMOUNT,
        TOTAL_ALLOWED_AMOUNT  = src.TOTAL_ALLOWED_AMOUNT,
        TOTAL_PAID_AMOUNT     = src.TOTAL_PAID_AMOUNT,
        TOTAL_MEMBER_RESP     = src.TOTAL_MEMBER_RESP,
        DENIAL_RATE           = src.DENIAL_RATE,
        SLA_BREACH_COUNT      = src.SLA_BREACH_COUNT,
        SLA_MET_COUNT         = src.SLA_MET_COUNT,
        SLA_BREACH_RATE       = src.SLA_BREACH_RATE,
        AVG_PROCESSING_HOURS  = src.AVG_PROCESSING_HOURS,
        MAX_PROCESSING_HOURS  = src.MAX_PROCESSING_HOURS,
        P90_PROCESSING_HOURS  = src.P90_PROCESSING_HOURS,
        RISK_SCORE            = src.RISK_SCORE,
        PRIMARY_RISK_CATEGORY = src.PRIMARY_RISK_CATEGORY,
        CHRONIC_CONDITION_COUNT = src.CHRONIC_CONDITION_COUNT,
        FIRST_SERVICE_DATE    = src.FIRST_SERVICE_DATE,
        LAST_SERVICE_DATE     = src.LAST_SERVICE_DATE,
        LAST_UPDATED_TS       = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (
        SUMMARY_ID, MEMBER_ID, PLAN_YEAR,
        TOTAL_CLAIMS, PAID_CLAIMS, DENIED_CLAIMS, PENDING_CLAIMS,
        UNIQUE_PROVIDERS, UNIQUE_CLAIM_TYPES,
        TOTAL_BILLED_AMOUNT, TOTAL_ALLOWED_AMOUNT, TOTAL_PAID_AMOUNT, TOTAL_MEMBER_RESP,
        DENIAL_RATE,
        SLA_BREACH_COUNT, SLA_MET_COUNT, SLA_BREACH_RATE,
        AVG_PROCESSING_HOURS, MAX_PROCESSING_HOURS, P90_PROCESSING_HOURS,
        RISK_SCORE, PRIMARY_RISK_CATEGORY, CHRONIC_CONDITION_COUNT,
        FIRST_SERVICE_DATE, LAST_SERVICE_DATE, LAST_UPDATED_TS,
        _SOURCE_SYSTEM, _LOADED_AT
    ) VALUES (
        UUID_STRING(), src.MEMBER_ID, src.PLAN_YEAR,
        src.TOTAL_CLAIMS, src.PAID_CLAIMS, src.DENIED_CLAIMS, src.PENDING_CLAIMS,
        src.UNIQUE_PROVIDERS, src.UNIQUE_CLAIM_TYPES,
        src.TOTAL_BILLED_AMOUNT, src.TOTAL_ALLOWED_AMOUNT, src.TOTAL_PAID_AMOUNT, src.TOTAL_MEMBER_RESP,
        src.DENIAL_RATE,
        src.SLA_BREACH_COUNT, src.SLA_MET_COUNT, src.SLA_BREACH_RATE,
        src.AVG_PROCESSING_HOURS, src.MAX_PROCESSING_HOURS, src.P90_PROCESSING_HOURS,
        src.RISK_SCORE, src.PRIMARY_RISK_CATEGORY, src.CHRONIC_CONDITION_COUNT,
        src.FIRST_SERVICE_DATE, src.LAST_SERVICE_DATE, CURRENT_TIMESTAMP(),
        'RISK_ADJ_PIPELINE', CURRENT_TIMESTAMP()
    );

    v_summary_updated := SQLROWCOUNT;

    -- ── Step 5: Compute risk tier counts ─────────────────────────────────
    SELECT
        COUNT(CASE WHEN RISK_SCORE >= 2.0 THEN 1 END),
        COUNT(CASE WHEN RISK_SCORE >= 3.0 THEN 1 END),
        AVG(RISK_SCORE)
    INTO :v_high_risk, :v_very_high_risk, :v_avg_risk
    FROM RAW_DEV.SUTTER_HEALTH.MEMBER_ENROLLMENT
    WHERE _IS_CURRENT = TRUE;

    -- ── Step 6: Finalize run record ───────────────────────────────────────
    v_end_ts       := CURRENT_TIMESTAMP();
    v_runtime_sec  := DATEDIFF('millisecond', :v_start_ts, :v_end_ts) / 1000.0;

    UPDATE RAW_DEV.SUTTER_HEALTH.RISK_ADJUSTMENT_DAILY_RUN
    SET
        RUN_END_TS             = :v_end_ts,
        RUNTIME_SECONDS        = :v_runtime_sec,
        CLAIMS_EVALUATED       = :v_claims_evaluated,
        MEMBERS_PROCESSED      = :v_members_processed,
        HCC_FLAGS_WRITTEN      = :v_hcc_flags_written,
        SUMMARY_ROWS_UPDATED   = :v_summary_updated,
        SLA_BREACHES_DETECTED  = :v_sla_breaches,
        SLA_COMPLIANCE_RATE    = :v_sla_rate,
        AVG_PROCESSING_HOURS   = :v_avg_proc_hrs,
        MAX_PROCESSING_HOURS   = :v_max_proc_hrs,
        HIGH_RISK_MEMBERS      = :v_high_risk,
        VERY_HIGH_RISK_MEMBERS = :v_very_high_risk,
        AVG_RISK_SCORE_RUN     = :v_avg_risk,
        RUN_STATUS             = 'COMPLETED'
    WHERE RUN_ID = :v_run_id;

    -- ── Step 7: Build result object ───────────────────────────────────────
    v_result := OBJECT_CONSTRUCT(
        'run_id',              :v_run_id,
        'run_date',            TO_VARCHAR(:RUN_DATE_PARAM, 'YYYY-MM-DD'),
        'runtime_seconds',     :v_runtime_sec,
        'claims_evaluated',    :v_claims_evaluated,
        'members_processed',   :v_members_processed,
        'hcc_flags_written',   :v_hcc_flags_written,
        'summary_rows_updated',:v_summary_updated,
        'sla_breaches',        :v_sla_breaches,
        'sla_compliance_rate', :v_sla_rate,
        'avg_processing_hours',:v_avg_proc_hrs,
        'high_risk_members',   :v_high_risk,
        'very_high_risk_members', :v_very_high_risk,
        'avg_risk_score',      :v_avg_risk,
        'warehouse',           CURRENT_WAREHOUSE(),
        'status',              'COMPLETED'
    );

    RETURN :v_result;

EXCEPTION WHEN OTHER THEN
    UPDATE RAW_DEV.SUTTER_HEALTH.RISK_ADJUSTMENT_DAILY_RUN
    SET RUN_STATUS    = 'FAILED',
        RUN_END_TS    = CURRENT_TIMESTAMP(),
        ERROR_MESSAGE = SQLERRM
    WHERE RUN_ID = :v_run_id;
    RAISE;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════
-- Demo execution — run on XS warehouse
-- ═══════════════════════════════════════════════════════════════════════════

USE WAREHOUSE SH_RISK_WH;  -- XS warehouse — demo the low compute cost

-- Run the pipeline for today
CALL RAW_DEV.SUTTER_HEALTH.SP_SH_RISK_ADJUSTMENT_DAILY_RUN(CURRENT_DATE(), 30);

-- View results
SELECT
    RUN_DATE,
    RUNTIME_SECONDS,
    CLAIMS_EVALUATED,
    MEMBERS_PROCESSED,
    HCC_FLAGS_WRITTEN,
    SLA_BREACHES_DETECTED,
    TO_PERCENTAGE(SLA_COMPLIANCE_RATE * 100, 1) AS SLA_COMPLIANCE_PCT,
    ROUND(AVG_PROCESSING_HOURS, 1)              AS AVG_PROC_HRS,
    HIGH_RISK_MEMBERS,
    VERY_HIGH_RISK_MEMBERS,
    ROUND(AVG_RISK_SCORE_RUN, 3)               AS AVG_RISK_SCORE,
    WAREHOUSE_USED,
    RUN_STATUS
FROM RAW_DEV.SUTTER_HEALTH.RISK_ADJUSTMENT_DAILY_RUN
ORDER BY RUN_START_TS DESC
LIMIT 5;
