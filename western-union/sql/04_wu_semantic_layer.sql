-- ============================================================================
-- WESTERN UNION — SEMANTIC LAYER: The Trust Boundary
-- ============================================================================
-- Native Semantic Views become the single source of truth.
-- Cortex Analyst queries these. Quality rules attach to these.
-- This IS the contract.
--
-- Schema Structure:
--   SEM_DEV.WU_REMITTANCE — Cross-domain WU semantic views
--
-- PREREQUISITES:
--   - sql/06_semantic_layer.sql executed (SEM_DEV database exists)
--   - 03_wu_curated_layer.sql executed (Dynamic Tables exist in CURATED_DEV)
--
-- RUN AS: DATA_ADMIN
-- ============================================================================

USE ROLE DATA_ADMIN;
USE DATABASE SEM_DEV;
USE WAREHOUSE ANALYTICS_WH;

-- ═══════════════════════════════════════════════════════════════════════════
-- CREATE WU SEMANTIC SCHEMA
-- ═══════════════════════════════════════════════════════════════════════════

CREATE SCHEMA IF NOT EXISTS SEM_DEV.WU_REMITTANCE
    COMMENT = 'Western Union remittance semantic views — Cortex Analyst, quality, compliance';

-- ═══════════════════════════════════════════════════════════════════════════
-- SEMANTIC VIEW 1: TRANSACTION_VOLUME_BY_CORRIDOR
-- ═══════════════════════════════════════════════════════════════════════════
-- Cortex Analyst: "Show me transaction volume by corridor last 30 days"

CREATE OR REPLACE VIEW SEM_DEV.WU_REMITTANCE.TRANSACTION_VOLUME_BY_CORRIDOR
    COMMENT = 'Cortex Analyst: "Show me transaction volume by corridor last 30 days"'
AS
SELECT
    c.CORRIDOR_CODE,
    c.ORIGIN_COUNTRY,
    c.DEST_COUNTRY,
    c.RISK_TIER,
    COUNT(t.TRANSACTION_ID)                                    AS TRANSACTION_COUNT,
    SUM(t.AMOUNT_USD)                                          AS TOTAL_VOLUME_USD,
    ROUND(AVG(t.AMOUNT_USD), 2)                                AS AVG_AMOUNT_USD,
    ROUND(
        COUNT(CASE WHEN t.CHANNEL IN ('MOBILE_APP', 'WEB') THEN 1 END) * 100.0
        / NULLIF(COUNT(*), 0), 2
    )                                                          AS DIGITAL_PCT,
    ROUND(
        COUNT(CASE WHEN t.COMPLIANCE_HOLD = TRUE THEN 1 END) * 100.0
        / NULLIF(COUNT(*), 0), 4
    )                                                          AS COMPLIANCE_HOLD_RATE,
    DATE_TRUNC('day', t.CREATED_AT)                            AS DATE_DAY
FROM CURATED_DEV.WU_PAYMENTS.FACT_TRANSACTIONS    t
JOIN CURATED_DEV.WU_PAYMENTS.DIM_CORRIDOR         c
    ON t.CORRIDOR = c.CORRIDOR_CODE
GROUP BY
    c.CORRIDOR_CODE,
    c.ORIGIN_COUNTRY,
    c.DEST_COUNTRY,
    c.RISK_TIER,
    DATE_TRUNC('day', t.CREATED_AT);

-- ═══════════════════════════════════════════════════════════════════════════
-- SEMANTIC VIEW 2: CUSTOMER_RISK_PROFILE
-- ═══════════════════════════════════════════════════════════════════════════
-- Unified customer view joining identity, transaction behavior, and
-- compliance signals.

CREATE OR REPLACE VIEW SEM_DEV.WU_REMITTANCE.CUSTOMER_RISK_PROFILE
    COMMENT = 'Unified customer view joining identity, transaction behavior, and compliance signals'
AS
SELECT
    cu.CUSTOMER_ID,
    cu.FULL_NAME,
    cu.COUNTRY,
    cu.KYC_STATUS,
    cu.KYC_EXPIRY_DATE,
    cu.RISK_LEVEL,
    COALESCE(bn.BENEFICIARY_COUNT, 0)                          AS BENEFICIARY_COUNT,
    COALESCE(tx.TOTAL_LIFETIME_TRANSACTIONS, 0)                AS TOTAL_LIFETIME_TRANSACTIONS,
    COALESCE(tx.TOTAL_LIFETIME_USD, 0)                         AS TOTAL_LIFETIME_USD,
    ROUND(COALESCE(tx.AVG_TRANSACTION_USD, 0), 2)              AS AVG_TRANSACTION_USD,
    COALESCE(sr.SAR_COUNT, 0)                                  AS SAR_COUNT,
    DATEDIFF('day', cu.KYC_DATE, CURRENT_DATE())               AS DAYS_SINCE_KYC,
    CASE WHEN cu.KYC_EXPIRY_DATE < CURRENT_DATE() THEN TRUE ELSE FALSE END AS KYC_IS_EXPIRED
FROM CURATED_DEV.WU_KYC.DIM_CUSTOMER cu
LEFT JOIN (
    SELECT CUSTOMER_ID, COUNT(*) AS BENEFICIARY_COUNT
    FROM CURATED_DEV.WU_KYC.DIM_BENEFICIARY
    GROUP BY CUSTOMER_ID
) bn ON cu.CUSTOMER_ID = bn.CUSTOMER_ID
LEFT JOIN (
    SELECT
        SENDER_ID,
        COUNT(*)       AS TOTAL_LIFETIME_TRANSACTIONS,
        SUM(AMOUNT_USD) AS TOTAL_LIFETIME_USD,
        AVG(AMOUNT_USD) AS AVG_TRANSACTION_USD
    FROM CURATED_DEV.WU_PAYMENTS.FACT_TRANSACTIONS
    GROUP BY SENDER_ID
) tx ON cu.CUSTOMER_ID = tx.SENDER_ID
LEFT JOIN (
    SELECT CUSTOMER_ID, COUNT(*) AS SAR_COUNT
    FROM CURATED_DEV.WU_COMPLIANCE.FACT_SARS
    GROUP BY CUSTOMER_ID
) sr ON cu.CUSTOMER_ID = sr.CUSTOMER_ID;

-- ═══════════════════════════════════════════════════════════════════════════
-- SEMANTIC VIEW 3: AGENT_COMPLIANCE_SCORECARD
-- ═══════════════════════════════════════════════════════════════════════════
-- Agent health view — the CDO's team uses this to identify compliance gaps.

CREATE OR REPLACE VIEW SEM_DEV.WU_REMITTANCE.AGENT_COMPLIANCE_SCORECARD
    COMMENT = 'Agent health view — the CDO''s team uses this to identify compliance gaps'
AS
SELECT
    a.AGENT_ID,
    a.AGENT_NAME,
    a.COUNTRY,
    a.CITY,
    a.AGENT_TYPE,
    a.COMPLIANCE_SCORE,
    a.MONTHLY_VOLUME                                           AS MONTHLY_VOLUME_USD,
    COALESCE(tx.TRANSACTION_COUNT_30D, 0)                      AS TRANSACTION_COUNT_30D,
    ROUND(COALESCE(tx.AVG_TRANSACTION_USD, 0), 2)              AS AVG_TRANSACTION_USD,
    ROUND(
        COALESCE(sr.SAR_COUNT, 0) * 1000.0
        / NULLIF(COALESCE(tx.TRANSACTION_COUNT_30D, 0), 0), 2
    )                                                          AS SAR_RATE_PER_1000,
    a.KYC_COMPLETION_RATE,
    COALESCE(a.SAR_COUNT, 0)                                   AS TOTAL_SAR_COUNT,
    CASE
        WHEN a.COMPLIANCE_SCORE < 50 THEN 'CRITICAL'
        WHEN a.COMPLIANCE_SCORE < 70 THEN 'HIGH'
        WHEN a.COMPLIANCE_SCORE < 85 THEN 'MEDIUM'
        ELSE 'LOW'
    END                                                        AS RISK_TIER
FROM CURATED_DEV.WU_PAYMENTS.DIM_AGENT a
LEFT JOIN (
    SELECT
        AGENT_ID,
        COUNT(*)        AS TRANSACTION_COUNT_30D,
        AVG(AMOUNT_USD) AS AVG_TRANSACTION_USD
    FROM CURATED_DEV.WU_PAYMENTS.FACT_TRANSACTIONS
    WHERE CREATED_AT >= DATEADD('day', -30, CURRENT_TIMESTAMP())
    GROUP BY AGENT_ID
) tx ON a.AGENT_ID = tx.AGENT_ID
LEFT JOIN (
    -- SARs linked to agents via transactions
    SELECT
        t.AGENT_ID,
        COUNT(DISTINCT s.SAR_ID) AS SAR_COUNT
    FROM CURATED_DEV.WU_COMPLIANCE.FACT_SARS s
    JOIN CURATED_DEV.WU_PAYMENTS.FACT_TRANSACTIONS t
        ON s.CUSTOMER_ID = t.SENDER_ID
    WHERE t.CREATED_AT >= DATEADD('day', -30, CURRENT_TIMESTAMP())
    GROUP BY t.AGENT_ID
) sr ON a.AGENT_ID = sr.AGENT_ID;

-- ═══════════════════════════════════════════════════════════════════════════
-- SEMANTIC VIEW 4: CORRIDOR_RISK_HEATMAP
-- ═══════════════════════════════════════════════════════════════════════════
-- Heatmap data for real-time corridor risk monitoring.

CREATE OR REPLACE VIEW SEM_DEV.WU_REMITTANCE.CORRIDOR_RISK_HEATMAP
    COMMENT = 'Heatmap data for real-time corridor risk monitoring'
AS
SELECT
    c.CORRIDOR_CODE,
    c.ORIGIN_COUNTRY,
    c.DEST_COUNTRY,
    c.RISK_TIER,
    COALESCE(t7.VOLUME_7D, 0)                                 AS VOLUME_7D,
    COALESCE(t30.VOLUME_30D, 0)                                AS VOLUME_30D,
    ROUND(
        CASE WHEN COALESCE(t30.VOLUME_30D, 0) > 0
             THEN (COALESCE(t7.VOLUME_7D, 0) * (30.0/7.0) - t30.VOLUME_30D)
                  / t30.VOLUME_30D * 100
             ELSE 0
        END, 2
    )                                                          AS VOLUME_CHANGE_PCT,
    ROUND(COALESCE(t7.AVG_AMOUNT_7D, 0), 2)                   AS AVG_AMOUNT_7D,
    ROUND(COALESCE(t7.COMPLIANCE_HOLD_RATE_7D, 0), 4)         AS COMPLIANCE_HOLD_RATE_7D,
    ROUND(
        COALESCE(sr.SAR_COUNT, 0) * 1000.0
        / NULLIF(COALESCE(t30.TXN_COUNT_30D, 0), 0), 4
    )                                                          AS SAR_FILING_RATE,
    c.IS_ACTIVE,
    c.REGULATORY_REGIME
FROM CURATED_DEV.WU_PAYMENTS.DIM_CORRIDOR c
LEFT JOIN (
    SELECT
        CORRIDOR,
        SUM(AMOUNT_USD)    AS VOLUME_7D,
        AVG(AMOUNT_USD)    AS AVG_AMOUNT_7D,
        COUNT(*)           AS TXN_COUNT_7D,
        COUNT(CASE WHEN COMPLIANCE_HOLD = TRUE THEN 1 END) * 100.0
            / NULLIF(COUNT(*), 0) AS COMPLIANCE_HOLD_RATE_7D
    FROM CURATED_DEV.WU_PAYMENTS.FACT_TRANSACTIONS
    WHERE CREATED_AT >= DATEADD('day', -7, CURRENT_TIMESTAMP())
    GROUP BY CORRIDOR
) t7 ON c.CORRIDOR_CODE = t7.CORRIDOR
LEFT JOIN (
    SELECT
        CORRIDOR,
        SUM(AMOUNT_USD) AS VOLUME_30D,
        COUNT(*)        AS TXN_COUNT_30D
    FROM CURATED_DEV.WU_PAYMENTS.FACT_TRANSACTIONS
    WHERE CREATED_AT >= DATEADD('day', -30, CURRENT_TIMESTAMP())
    GROUP BY CORRIDOR
) t30 ON c.CORRIDOR_CODE = t30.CORRIDOR
LEFT JOIN (
    -- SARs per corridor via transactions
    SELECT
        t.CORRIDOR,
        COUNT(DISTINCT s.SAR_ID) AS SAR_COUNT
    FROM CURATED_DEV.WU_COMPLIANCE.FACT_SARS s
    JOIN CURATED_DEV.WU_PAYMENTS.FACT_TRANSACTIONS t
        ON s.CUSTOMER_ID = t.SENDER_ID
    WHERE t.CREATED_AT >= DATEADD('day', -30, CURRENT_TIMESTAMP())
    GROUP BY t.CORRIDOR
) sr ON c.CORRIDOR_CODE = sr.CORRIDOR;

-- ═══════════════════════════════════════════════════════════════════════════
-- VERIFICATION
-- ═══════════════════════════════════════════════════════════════════════════

SELECT TABLE_NAME, COMMENT
FROM SEM_DEV.INFORMATION_SCHEMA.VIEWS
WHERE TABLE_SCHEMA = 'WU_REMITTANCE'
ORDER BY TABLE_NAME;

SELECT '04_wu_semantic_layer.sql completed successfully' AS STATUS;
