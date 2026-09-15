-- ============================================================================
-- SUTTER HEALTH DEMO — Semantic Layer: Cortex Analyst Natural Language
-- ============================================================================
--
-- Creates two Semantic Views on top of the curated Dynamic Tables to power
-- plain-English queries via Cortex Analyst.
--
-- CLAIMS_ANALYTICS        — SLA, cost, denial, and claims volume questions
-- RISK_ADJUSTMENT_ANALYTICS — HCC flags, risk scores, member risk distribution
--
-- DEMO QUESTIONS to test in the Snowsight Cortex Analyst UI:
--   1. "How many claims missed the 24-hour SLA last month?"
--   2. "What is the average processing time by claim type?"
--   3. "Show me the top 10 providers by risk adjustment flag volume."
--   4. "What percentage of high-risk members are in care management?"
--   5. "What was the total paid amount for CARDIAC claims this year?"
--
-- Prerequisites: 04_sh_curated_layer.sql
-- RUN AS: DATA_ADMIN
-- ============================================================================

USE ROLE DATA_ADMIN;
USE DATABASE SEM_DEV;
USE SCHEMA SUTTER_HEALTH;
USE WAREHOUSE ANALYTICS_WH;

-- ═══════════════════════════════════════════════════════════════════════════
-- CLAIMS_ANALYTICS — SLA, cost, denial, and volume NL questions
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE SEMANTIC VIEW SEM_DEV.SUTTER_HEALTH.CLAIMS_ANALYTICS
    COMMENT = 'Healthcare claims analytics semantic view. Powers Cortex Analyst natural language queries on SLA performance, costs, and claim volume.'
    TABLES (
        claims AS CURATED_DEV.SUTTER_HEALTH.FACT_CLAIMS
            PRIMARY KEY (CLAIM_ID, CLAIM_LINE_NUMBER),
        member AS CURATED_DEV.SUTTER_HEALTH.DIM_MEMBER
            PRIMARY KEY (MEMBER_ID),
        provider AS CURATED_DEV.SUTTER_HEALTH.DIM_PROVIDER
            PRIMARY KEY (PROVIDER_NPI)
    )
    RELATIONSHIPS (
        claims(MEMBER_ID) REFERENCES member(MEMBER_ID),
        claims(PROVIDER_NPI) REFERENCES provider(PROVIDER_NPI)
    )
    DIMENSIONS (
        -- Claim classification
        claims.CLAIM_TYPE           AS claim_type,
        claims.CLAIM_SUBTYPE        AS claim_subtype,
        claims.CLINICAL_CATEGORY    AS clinical_category,
        claims.PLACE_OF_SERVICE_DESC AS place_of_service,
        claims.CLAIM_STATUS         AS claim_status,
        claims.NETWORK_STATUS       AS network_status,
        claims.DENIAL_REASON_CODE   AS denial_reason_code,

        -- Diagnosis
        claims.PRIMARY_DX_CODE      AS primary_dx_code,

        -- SLA
        claims.SLA_MET              AS sla_met,
        claims.SLA_TARGET_HOURS     AS sla_target_hours,

        -- Date dimensions
        claims.SERVICE_DATE         AS service_date,
        claims.SERVICE_MONTH        AS service_month,
        claims.SERVICE_QUARTER      AS service_quarter,
        claims.PLAN_YEAR            AS plan_year,

        -- Member attributes
        member.PLAN_TYPE            AS plan_type,
        member.PRODUCT_LINE         AS product_line,
        member.RISK_CATEGORY        AS member_risk_category,
        member.AGE_BAND             AS member_age_band,
        member.MEMBER_STATE         AS member_state,
        member.DUAL_ELIGIBLE        AS dual_eligible,
        member.ENROLLMENT_STATUS    AS enrollment_status,

        -- Provider attributes
        provider.SPECIALTY_DESC     AS provider_specialty,
        provider.PROVIDER_FULL_NAME AS provider_name,
        provider.QUALITY_TIER       AS provider_quality_tier,
        provider.PRACTICE_STATE     AS provider_state,
        provider.PRIMARY_CARE_FLAG  AS is_primary_care,
        provider.BOARD_CERTIFIED    AS board_certified
    )
    METRICS (
        -- Volume
        COUNT(claims.CLAIM_ID)                  AS total_claims
            COMMENT = 'Total number of claim lines',

        COUNT(DISTINCT claims.CLAIM_ID)         AS unique_claims
            COMMENT = 'Number of unique claims (distinct claim IDs)',

        COUNT(DISTINCT claims.MEMBER_ID)        AS members_with_claims
            COMMENT = 'Number of distinct members who submitted at least one claim',

        -- Financial
        SUM(claims.BILLED_AMOUNT)               AS total_billed_amount
            COMMENT = 'Sum of all billed charges in dollars',

        SUM(claims.PAID_AMOUNT)                 AS total_paid_amount
            COMMENT = 'Sum of all payments made to providers in dollars',

        AVG(claims.BILLED_AMOUNT)               AS avg_billed_amount
            COMMENT = 'Average billed amount per claim line',

        -- SLA metrics — primary demo KPIs
        COUNT(CASE WHEN claims.SLA_MET = FALSE THEN claims.CLAIM_ID END)
                                                AS sla_breach_count
            COMMENT = 'Number of claims that missed the 24-hour adjudication SLA',

        COUNT(CASE WHEN claims.SLA_MET = TRUE THEN claims.CLAIM_ID END)
                                                AS sla_met_count
            COMMENT = 'Number of claims processed within the 24-hour SLA',

        AVG(claims.PROCESSING_HOURS)            AS avg_processing_hours
            COMMENT = 'Average time from claim receipt to adjudication in hours',

        MAX(claims.PROCESSING_HOURS)            AS max_processing_hours
            COMMENT = 'Worst-case adjudication time in hours',

        -- Denial metrics
        COUNT(CASE WHEN claims.CLAIM_STATUS = 'DENIED' THEN claims.CLAIM_ID END)
                                                AS denied_claim_count
            COMMENT = 'Number of denied claims'
    );

-- ═══════════════════════════════════════════════════════════════════════════
-- RISK_ADJUSTMENT_ANALYTICS — HCC flags, risk scores, member risk
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE SEMANTIC VIEW SEM_DEV.SUTTER_HEALTH.RISK_ADJUSTMENT_ANALYTICS
    COMMENT = 'Risk adjustment analytics semantic view. Powers Cortex Analyst queries on HCC flags, risk scores, and member risk distribution.'
    TABLES (
        risk_adj AS CURATED_DEV.SUTTER_HEALTH.FACT_RISK_ADJ
            PRIMARY KEY (MEMBER_ID, PLAN_YEAR),
        flags AS RAW_DEV.SUTTER_HEALTH.RISK_ADJUSTMENT_FLAGS
            PRIMARY KEY (FLAG_ID),
        provider AS CURATED_DEV.SUTTER_HEALTH.DIM_PROVIDER
            PRIMARY KEY (PROVIDER_NPI)
    )
    RELATIONSHIPS (
        flags(MEMBER_ID) REFERENCES risk_adj(MEMBER_ID)
    )
    DIMENSIONS (
        -- HCC dimensions
        flags.HCC_CODE          AS hcc_code,
        flags.HCC_DESCRIPTION   AS hcc_description,
        flags.ICD10_CODE        AS icd10_code,
        flags.FLAG_SOURCE       AS flag_source,
        flags.FLAG_STATUS       AS flag_status,
        flags.FLAG_DATE         AS flag_date,
        flags.PLAN_YEAR         AS plan_year,
        flags.CLAIM_SLA_MET     AS claim_sla_met,

        -- Member risk profile
        risk_adj.RISK_CATEGORY          AS risk_category,
        risk_adj.PLAN_TYPE              AS plan_type,
        risk_adj.PRODUCT_LINE           AS product_line,
        risk_adj.AGE_BAND               AS member_age_band,
        risk_adj.MEMBER_STATE           AS member_state,
        risk_adj.CARE_MANAGEMENT_FLAG   AS in_care_management,

        -- Provider
        provider.SPECIALTY_DESC         AS provider_specialty,
        provider.PROVIDER_FULL_NAME     AS provider_name,
        provider.QUALITY_TIER           AS provider_quality_tier
    )
    METRICS (
        COUNT(flags.FLAG_ID)                AS total_hcc_flags
            COMMENT = 'Total number of active HCC risk adjustment flags',

        COUNT(DISTINCT flags.MEMBER_ID)     AS flagged_member_count
            COMMENT = 'Number of distinct members with at least one HCC flag',

        COUNT(DISTINCT flags.HCC_CODE)      AS unique_hcc_categories
            COMMENT = 'Number of distinct HCC risk categories flagged',

        AVG(risk_adj.RISK_SCORE)            AS avg_risk_score
            COMMENT = 'Average CMS-HCC composite risk score across the member population',

        MAX(risk_adj.RISK_SCORE)            AS max_risk_score
            COMMENT = 'Highest CMS-HCC risk score in the population',

        SUM(flags.RISK_WEIGHT)              AS total_risk_weight
            COMMENT = 'Sum of HCC risk weights (proxy for total risk-adjusted premium impact)',

        AVG(flags.RISK_WEIGHT)              AS avg_hcc_weight
            COMMENT = 'Average HCC risk weight per flag',

        COUNT(CASE WHEN flags.CLAIM_SLA_MET = FALSE THEN flags.FLAG_ID END)
                                            AS flags_with_sla_breach
            COMMENT = 'HCC flags whose source claim missed the 24-hour SLA',

        COUNT(CASE WHEN risk_adj.CARE_MANAGEMENT_FLAG = TRUE THEN risk_adj.MEMBER_ID END)
                                            AS care_managed_member_count
            COMMENT = 'Members with active HCC flags who are enrolled in care management',

        AVG(flags.CLAIM_PROCESSING_HOURS)   AS avg_claim_processing_hrs
            COMMENT = 'Average processing time for claims that generated HCC flags'
    );

-- ═══════════════════════════════════════════════════════════════════════════
-- Grant semantic view access to demo roles
-- ═══════════════════════════════════════════════════════════════════════════

GRANT SELECT ON SEMANTIC VIEW SEM_DEV.SUTTER_HEALTH.CLAIMS_ANALYTICS          TO ROLE SH_RISK_MANAGER;
GRANT SELECT ON SEMANTIC VIEW SEM_DEV.SUTTER_HEALTH.CLAIMS_ANALYTICS          TO ROLE SH_CLAIMS_ANALYST;
GRANT SELECT ON SEMANTIC VIEW SEM_DEV.SUTTER_HEALTH.CLAIMS_ANALYTICS          TO ROLE SH_EXECUTIVE;
GRANT SELECT ON SEMANTIC VIEW SEM_DEV.SUTTER_HEALTH.RISK_ADJUSTMENT_ANALYTICS TO ROLE SH_RISK_MANAGER;
GRANT SELECT ON SEMANTIC VIEW SEM_DEV.SUTTER_HEALTH.RISK_ADJUSTMENT_ANALYTICS TO ROLE SH_CLAIMS_ANALYST;

-- ═══════════════════════════════════════════════════════════════════════════
-- Cortex Analyst — test the 3 required demo questions
-- ═══════════════════════════════════════════════════════════════════════════
-- NOTE: Run these one at a time in the Snowsight Cortex Analyst UI, or
-- use the SELECT SNOWFLAKE.CORTEX.COMPLETE() API below for programmatic test.

-- ── Demo Question 1 ────────────────────────────────────────────────────────
-- "How many claims missed the 24-hour SLA last month?"
-- Expected: filters SERVICE_MONTH = DATE_TRUNC('month', DATEADD('month',-1,CURRENT_DATE))
--           returns sla_breach_count
SELECT SNOWFLAKE.CORTEX.COMPLETE(
    'mistral-large2',
    ARRAY_CONSTRUCT(
        OBJECT_CONSTRUCT('role', 'system', 'content',
            'You are a healthcare claims analyst. The user has access to a semantic view called
CLAIMS_ANALYTICS in SEM_DEV.SUTTER_HEALTH. Generate a Snowflake SQL query using that semantic view
to answer the user question. Return only the SQL query, no explanation.'),
        OBJECT_CONSTRUCT('role', 'user', 'content',
            'How many claims missed the 24-hour SLA last month?')
    )
) AS generated_sql_q1;

-- ── Demo Question 2 ────────────────────────────────────────────────────────
-- "What is the average processing time by claim type?"
-- Expected: GROUP BY claim_type, AVG(avg_processing_hours)
SELECT SNOWFLAKE.CORTEX.COMPLETE(
    'mistral-large2',
    ARRAY_CONSTRUCT(
        OBJECT_CONSTRUCT('role', 'system', 'content',
            'You are a healthcare claims analyst. The user has access to a semantic view called
CLAIMS_ANALYTICS in SEM_DEV.SUTTER_HEALTH. Generate a Snowflake SQL query using that semantic view
to answer the user question. Return only the SQL query, no explanation.'),
        OBJECT_CONSTRUCT('role', 'user', 'content',
            'What is the average processing time by claim type?')
    )
) AS generated_sql_q2;

-- ── Demo Question 3 ────────────────────────────────────────────────────────
-- "Show me the top 10 providers by risk adjustment flag volume."
-- Expected: joins to provider via RISK_ADJUSTMENT_ANALYTICS, GROUP BY provider_name,
--           ORDER BY total_hcc_flags DESC LIMIT 10
SELECT SNOWFLAKE.CORTEX.COMPLETE(
    'mistral-large2',
    ARRAY_CONSTRUCT(
        OBJECT_CONSTRUCT('role', 'system', 'content',
            'You are a healthcare claims analyst. The user has access to a semantic view called
RISK_ADJUSTMENT_ANALYTICS in SEM_DEV.SUTTER_HEALTH. Generate a Snowflake SQL query using that semantic
view to answer the user question. Return only the SQL query, no explanation.'),
        OBJECT_CONSTRUCT('role', 'user', 'content',
            'Show me the top 10 providers by risk adjustment flag volume.')
    )
) AS generated_sql_q3;

-- ── Direct semantic view queries (non-AI, for validation) ─────────────────

-- Q1 direct: SLA breaches last month
SELECT
    COUNT(CASE WHEN sla_met = FALSE THEN claim_id END)  AS sla_breach_count,
    COUNT(CASE WHEN sla_met = TRUE  THEN claim_id END)  AS sla_met_count,
    ROUND(
        COUNT(CASE WHEN sla_met = FALSE THEN claim_id END) * 100.0 /
        NULLIF(COUNT(claim_id), 0), 1
    ) AS breach_rate_pct
FROM SEM_DEV.SUTTER_HEALTH.CLAIMS_ANALYTICS
WHERE service_month = DATE_TRUNC('month', DATEADD('month', -1, CURRENT_DATE()));

-- Q2 direct: Avg processing time by claim type
SELECT
    claim_type,
    ROUND(avg_processing_hours, 2)  AS avg_processing_hours,
    total_claims
FROM SEM_DEV.SUTTER_HEALTH.CLAIMS_ANALYTICS
GROUP BY claim_type, avg_processing_hours, total_claims
ORDER BY avg_processing_hours DESC;

-- Q3 direct: Top 10 providers by HCC flag volume
SELECT
    provider_name,
    provider_specialty,
    provider_quality_tier,
    total_hcc_flags,
    flagged_member_count,
    ROUND(avg_hcc_weight, 4)        AS avg_hcc_weight
FROM SEM_DEV.SUTTER_HEALTH.RISK_ADJUSTMENT_ANALYTICS
GROUP BY provider_name, provider_specialty, provider_quality_tier,
         total_hcc_flags, flagged_member_count, avg_hcc_weight
ORDER BY total_hcc_flags DESC
LIMIT 10;
