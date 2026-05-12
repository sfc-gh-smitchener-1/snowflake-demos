-- ============================================================================
-- WESTERN UNION — QUALITY AUTOMATION: DMFs + AI Remediation
-- ============================================================================
-- Demonstrates how Data Metric Functions monitor quality continuously,
-- and Cortex AI can auto-remediate recoverable issues.
-- This answers CDO Surekha Durvasula's Question B completely:
-- "If my semantic schema definitions live in Snowflake, can the platform
--  self-enforce quality and auto-remediate?"
--
-- PREREQUISITES:
--   - 03_wu_curated_layer.sql executed (Dynamic Tables in CURATED_DEV)
--   - 05_wu_contracts.sql executed (WU_QUARANTINE table exists)
--
-- RUN AS: DATA_ADMIN
-- ============================================================================

USE ROLE DATA_ADMIN;
USE DATABASE CURATED_DEV;
USE WAREHOUSE TRANSFORM_WH;

-- ═══════════════════════════════════════════════════════════════════════════
-- SECTION 1: DATA METRIC FUNCTIONS (DMFs)
-- ═══════════════════════════════════════════════════════════════════════════

-- Freshness DMF on FACT_TRANSACTIONS
-- Returns minutes since last transaction — alerts if pipeline stalls
CREATE OR REPLACE DATA METRIC FUNCTION CURATED_DEV.WU_PAYMENTS.DMF_TRANSACTION_FRESHNESS(
    ARG_T TABLE(CREATED_AT TIMESTAMP_NTZ)
)
RETURNS NUMBER
AS
$$
    SELECT DATEDIFF('minute', MAX(CREATED_AT), CURRENT_TIMESTAMP()) FROM ARG_T
$$;

-- Completeness DMF on DIM_CUSTOMER
-- Returns % of non-null KYC fields (4 key fields checked)
CREATE OR REPLACE DATA METRIC FUNCTION CURATED_DEV.WU_KYC.DMF_CUSTOMER_COMPLETENESS(
    ARG_T TABLE(KYC_STATUS VARCHAR, KYC_DATE DATE, KYC_EXPIRY_DATE DATE, PHONE VARCHAR)
)
RETURNS NUMBER
AS
$$
    SELECT ROUND(
        (COUNT(CASE WHEN KYC_STATUS IS NOT NULL THEN 1 END) +
         COUNT(CASE WHEN KYC_DATE IS NOT NULL THEN 1 END) +
         COUNT(CASE WHEN KYC_EXPIRY_DATE IS NOT NULL THEN 1 END) +
         COUNT(CASE WHEN PHONE IS NOT NULL THEN 1 END)) * 100.0 /
        (COUNT(*) * 4), 2
    ) FROM ARG_T
$$;

-- Accuracy DMF: % of corridors that are valid ISO code pairs (XX_YY)
CREATE OR REPLACE DATA METRIC FUNCTION CURATED_DEV.WU_PAYMENTS.DMF_CORRIDOR_ACCURACY(
    ARG_T TABLE(CORRIDOR VARCHAR)
)
RETURNS NUMBER
AS
$$
    SELECT ROUND(
        COUNT(CASE WHEN CORRIDOR RLIKE '^[A-Z]{2}_[A-Z]{2}$' THEN 1 END) * 100.0
        / NULLIF(COUNT(*), 0), 2
    ) FROM ARG_T
$$;

-- Amount positivity DMF: % of transactions with positive amounts
CREATE OR REPLACE DATA METRIC FUNCTION CURATED_DEV.WU_PAYMENTS.DMF_AMOUNT_POSITIVITY(
    ARG_T TABLE(AMOUNT_USD NUMBER)
)
RETURNS NUMBER
AS
$$
    SELECT ROUND(
        COUNT(CASE WHEN AMOUNT_USD > 0 THEN 1 END) * 100.0
        / NULLIF(COUNT(*), 0), 2
    ) FROM ARG_T
$$;

-- Beneficiary name completeness DMF
CREATE OR REPLACE DATA METRIC FUNCTION CURATED_DEV.WU_KYC.DMF_BENEFICIARY_NAME_COMPLETENESS(
    ARG_T TABLE(FULL_NAME VARCHAR)
)
RETURNS NUMBER
AS
$$
    SELECT ROUND(
        COUNT(CASE WHEN FULL_NAME IS NOT NULL AND TRIM(FULL_NAME) != '' THEN 1 END) * 100.0
        / NULLIF(COUNT(*), 0), 2
    ) FROM ARG_T
$$;

-- Country ISO compliance DMF
CREATE OR REPLACE DATA METRIC FUNCTION CURATED_DEV.WU_KYC.DMF_COUNTRY_ISO_COMPLIANCE(
    ARG_T TABLE(COUNTRY VARCHAR)
)
RETURNS NUMBER
AS
$$
    SELECT ROUND(
        COUNT(CASE WHEN COUNTRY RLIKE '^[A-Z]{2}$' THEN 1 END) * 100.0
        / NULLIF(COUNT(*), 0), 2
    ) FROM ARG_T
$$;

-- ═══════════════════════════════════════════════════════════════════════════
-- ATTACH DMFs TO TABLES
-- ═══════════════════════════════════════════════════════════════════════════

-- FACT_TRANSACTIONS: trigger on changes (near real-time monitoring)
ALTER TABLE CURATED_DEV.WU_PAYMENTS.FACT_TRANSACTIONS
    SET DATA_METRIC_SCHEDULE = 'TRIGGER_ON_CHANGES';

ALTER TABLE CURATED_DEV.WU_PAYMENTS.FACT_TRANSACTIONS
    ADD DATA METRIC FUNCTION CURATED_DEV.WU_PAYMENTS.DMF_TRANSACTION_FRESHNESS ON (CREATED_AT);

ALTER TABLE CURATED_DEV.WU_PAYMENTS.FACT_TRANSACTIONS
    ADD DATA METRIC FUNCTION CURATED_DEV.WU_PAYMENTS.DMF_CORRIDOR_ACCURACY ON (CORRIDOR);

ALTER TABLE CURATED_DEV.WU_PAYMENTS.FACT_TRANSACTIONS
    ADD DATA METRIC FUNCTION CURATED_DEV.WU_PAYMENTS.DMF_AMOUNT_POSITIVITY ON (AMOUNT_USD);

-- DIM_CUSTOMER: trigger on changes
ALTER TABLE CURATED_DEV.WU_KYC.DIM_CUSTOMER
    SET DATA_METRIC_SCHEDULE = 'TRIGGER_ON_CHANGES';

ALTER TABLE CURATED_DEV.WU_KYC.DIM_CUSTOMER
    ADD DATA METRIC FUNCTION CURATED_DEV.WU_KYC.DMF_CUSTOMER_COMPLETENESS
    ON (KYC_STATUS, KYC_DATE, KYC_EXPIRY_DATE, PHONE);

ALTER TABLE CURATED_DEV.WU_KYC.DIM_CUSTOMER
    ADD DATA METRIC FUNCTION CURATED_DEV.WU_KYC.DMF_COUNTRY_ISO_COMPLIANCE ON (COUNTRY);

-- DIM_BENEFICIARY: trigger on changes
ALTER TABLE CURATED_DEV.WU_KYC.DIM_BENEFICIARY
    SET DATA_METRIC_SCHEDULE = 'TRIGGER_ON_CHANGES';

ALTER TABLE CURATED_DEV.WU_KYC.DIM_BENEFICIARY
    ADD DATA METRIC FUNCTION CURATED_DEV.WU_KYC.DMF_BENEFICIARY_NAME_COMPLETENESS ON (FULL_NAME);

ALTER TABLE CURATED_DEV.WU_KYC.DIM_BENEFICIARY
    ADD DATA METRIC FUNCTION CURATED_DEV.WU_KYC.DMF_COUNTRY_ISO_COMPLIANCE ON (COUNTRY);

-- ═══════════════════════════════════════════════════════════════════════════
-- SECTION 2: AI-POWERED REMEDIATION PROCEDURES
-- ═══════════════════════════════════════════════════════════════════════════

-- SP_WU_REMEDIATE_COUNTRY_CODES
-- Uses Cortex AI to standardize malformed country codes in DIM_BENEFICIARY
CREATE OR REPLACE PROCEDURE CURATED_DEV.WU_KYC.SP_WU_REMEDIATE_COUNTRY_CODES()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
BEGIN
    LET remediated_count INTEGER := 0;
    LET failed_count INTEGER := 0;
    LET total_found INTEGER := 0;

    -- Find records with invalid country codes
    LET invalid_cursor CURSOR FOR
        SELECT BENEFICIARY_ID, COUNTRY
        FROM CURATED_DEV.WU_KYC.DIM_BENEFICIARY
        WHERE COUNTRY IS NOT NULL
          AND COUNTRY NOT RLIKE '^[A-Z]{2}$'
        LIMIT 500;

    FOR rec IN invalid_cursor DO
        total_found := total_found + 1;

        BEGIN
            -- Use Cortex AI to convert country name/code to ISO 3166-1 alpha-2
            LET ai_result VARCHAR;
            SELECT TRIM(SNOWFLAKE.CORTEX.COMPLETE(
                'mistral-large',
                'Convert this country name or code to a 2-letter ISO 3166-1 alpha-2 code. Return ONLY the 2-letter code, nothing else: ' || rec.COUNTRY
            )) INTO :ai_result;

            -- Validate the AI result is actually a 2-letter code
            IF (ai_result RLIKE '^[A-Z]{2}$') THEN
                -- Update the record
                UPDATE CURATED_DEV.WU_KYC.DIM_BENEFICIARY
                SET COUNTRY = :ai_result
                WHERE BENEFICIARY_ID = rec.BENEFICIARY_ID;

                -- Log to quarantine with remediation info
                INSERT INTO GOVERNANCE.CONTRACTS.WU_QUARANTINE (
                    SOURCE_TABLE, RECORD_ID, RULE_ID, RULE_NAME,
                    VIOLATION_DETAILS, REMEDIATED, REMEDIATED_AT, REMEDIATION_METHOD
                ) VALUES (
                    'CURATED_DEV.WU_KYC.DIM_BENEFICIARY',
                    rec.BENEFICIARY_ID,
                    'WU-QR-BEN-002',
                    'WU_BEN_COUNTRY_ISO',
                    OBJECT_CONSTRUCT(
                        'original_value', rec.COUNTRY,
                        'corrected_value', :ai_result,
                        'model', 'mistral-large'
                    ),
                    TRUE,
                    CURRENT_TIMESTAMP(),
                    'AI_COUNTRY_STANDARDIZATION'
                );

                remediated_count := remediated_count + 1;
            ELSE
                failed_count := failed_count + 1;
            END IF;

        EXCEPTION
            WHEN OTHER THEN
                failed_count := failed_count + 1;
        END;
    END FOR;

    RETURN OBJECT_CONSTRUCT(
        'status', CASE WHEN failed_count = 0 AND remediated_count > 0 THEN 'SUCCESS'
                       WHEN remediated_count > 0 THEN 'PARTIAL'
                       WHEN total_found = 0 THEN 'NO_ISSUES_FOUND'
                       ELSE 'FAILED' END,
        'total_invalid_found', total_found,
        'remediated', remediated_count,
        'failed', failed_count,
        'method', 'AI_COUNTRY_STANDARDIZATION'
    );
END;

-- SP_WU_REMEDIATE_PHONE_FORMAT
-- Uses Cortex AI to normalize phone numbers in DIM_CUSTOMER
CREATE OR REPLACE PROCEDURE CURATED_DEV.WU_KYC.SP_WU_REMEDIATE_PHONE_FORMAT()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
BEGIN
    LET remediated_count INTEGER := 0;
    LET failed_count INTEGER := 0;
    LET total_found INTEGER := 0;

    -- Find records with invalid phone formats (not E.164)
    LET invalid_cursor CURSOR FOR
        SELECT CUSTOMER_ID, PHONE, COUNTRY
        FROM CURATED_DEV.WU_KYC.DIM_CUSTOMER
        WHERE PHONE IS NOT NULL
          AND PHONE NOT RLIKE '^\\+[1-9]\\d{1,14}$'
        LIMIT 500;

    FOR rec IN invalid_cursor DO
        total_found := total_found + 1;

        BEGIN
            LET ai_result VARCHAR;
            SELECT TRIM(SNOWFLAKE.CORTEX.COMPLETE(
                'mistral-large',
                'Convert this phone number to E.164 international format (starting with +). ' ||
                'The person is from country code ' || COALESCE(rec.COUNTRY, 'US') || '. ' ||
                'Return ONLY the E.164 phone number, nothing else: ' || rec.PHONE
            )) INTO :ai_result;

            -- Validate the AI result matches E.164
            IF (ai_result RLIKE '^\\+[1-9]\\d{1,14}$') THEN
                UPDATE CURATED_DEV.WU_KYC.DIM_CUSTOMER
                SET PHONE = :ai_result
                WHERE CUSTOMER_ID = rec.CUSTOMER_ID;

                INSERT INTO GOVERNANCE.CONTRACTS.WU_QUARANTINE (
                    SOURCE_TABLE, RECORD_ID, RULE_ID, RULE_NAME,
                    VIOLATION_DETAILS, REMEDIATED, REMEDIATED_AT, REMEDIATION_METHOD
                ) VALUES (
                    'CURATED_DEV.WU_KYC.DIM_CUSTOMER',
                    rec.CUSTOMER_ID,
                    'WU-QR-CUST-002',
                    'WU_CUST_PHONE_FORMAT',
                    OBJECT_CONSTRUCT(
                        'original_value', rec.PHONE,
                        'corrected_value', :ai_result,
                        'country_hint', rec.COUNTRY,
                        'model', 'mistral-large'
                    ),
                    TRUE,
                    CURRENT_TIMESTAMP(),
                    'AI_PHONE_NORMALIZATION'
                );

                remediated_count := remediated_count + 1;
            ELSE
                failed_count := failed_count + 1;
            END IF;

        EXCEPTION
            WHEN OTHER THEN
                failed_count := failed_count + 1;
        END;
    END FOR;

    RETURN OBJECT_CONSTRUCT(
        'status', CASE WHEN failed_count = 0 AND remediated_count > 0 THEN 'SUCCESS'
                       WHEN remediated_count > 0 THEN 'PARTIAL'
                       WHEN total_found = 0 THEN 'NO_ISSUES_FOUND'
                       ELSE 'FAILED' END,
        'total_invalid_found', total_found,
        'remediated', remediated_count,
        'failed', failed_count,
        'method', 'AI_PHONE_NORMALIZATION'
    );
END;

-- ═══════════════════════════════════════════════════════════════════════════
-- SECTION 3: QUALITY DASHBOARD DATA PROCEDURE
-- ═══════════════════════════════════════════════════════════════════════════

-- SP_WU_QUALITY_DASHBOARD_DATA
-- Returns a summary view of all WU quality metrics
CREATE OR REPLACE PROCEDURE CURATED_DEV.WU_KYC.SP_WU_QUALITY_DASHBOARD_DATA()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
BEGIN
    -- Table row counts
    LET txn_count INTEGER;
    SELECT COUNT(*) INTO :txn_count FROM CURATED_DEV.WU_PAYMENTS.FACT_TRANSACTIONS;

    LET cust_count INTEGER;
    SELECT COUNT(*) INTO :cust_count FROM CURATED_DEV.WU_KYC.DIM_CUSTOMER;

    LET ben_count INTEGER;
    SELECT COUNT(*) INTO :ben_count FROM CURATED_DEV.WU_KYC.DIM_BENEFICIARY;

    -- Freshness: minutes since last transaction
    LET txn_freshness INTEGER;
    SELECT DATEDIFF('minute', MAX(CREATED_AT), CURRENT_TIMESTAMP())
    INTO :txn_freshness FROM CURATED_DEV.WU_PAYMENTS.FACT_TRANSACTIONS;

    -- Customer completeness score
    LET cust_completeness NUMBER(5,2);
    SELECT ROUND(
        (COUNT(CASE WHEN KYC_STATUS IS NOT NULL THEN 1 END) +
         COUNT(CASE WHEN KYC_DATE IS NOT NULL THEN 1 END) +
         COUNT(CASE WHEN KYC_EXPIRY_DATE IS NOT NULL THEN 1 END) +
         COUNT(CASE WHEN PHONE IS NOT NULL THEN 1 END)) * 100.0 /
        (COUNT(*) * 4), 2
    ) INTO :cust_completeness FROM CURATED_DEV.WU_KYC.DIM_CUSTOMER;

    -- Corridor accuracy
    LET corridor_accuracy NUMBER(5,2);
    SELECT ROUND(
        COUNT(CASE WHEN CORRIDOR RLIKE '^[A-Z]{2}_[A-Z]{2}$' THEN 1 END) * 100.0
        / NULLIF(COUNT(*), 0), 2
    ) INTO :corridor_accuracy FROM CURATED_DEV.WU_PAYMENTS.FACT_TRANSACTIONS;

    -- Country ISO compliance (beneficiaries)
    LET ben_country_iso NUMBER(5,2);
    SELECT ROUND(
        COUNT(CASE WHEN COUNTRY RLIKE '^[A-Z]{2}$' THEN 1 END) * 100.0
        / NULLIF(COUNT(*), 0), 2
    ) INTO :ben_country_iso FROM CURATED_DEV.WU_KYC.DIM_BENEFICIARY;

    -- Quarantine stats
    LET quarantine_total INTEGER;
    SELECT COUNT(*) INTO :quarantine_total
    FROM GOVERNANCE.CONTRACTS.WU_QUARANTINE;

    LET quarantine_remediated INTEGER;
    SELECT COUNT(*) INTO :quarantine_remediated
    FROM GOVERNANCE.CONTRACTS.WU_QUARANTINE
    WHERE REMEDIATED = TRUE;

    LET remediation_rate NUMBER(5,2);
    SELECT ROUND(
        :quarantine_remediated * 100.0 / NULLIF(:quarantine_total, 0), 2
    ) INTO :remediation_rate;

    -- Contract validation results (latest)
    LET contracts_passed INTEGER;
    LET contracts_failed INTEGER;
    SELECT
        COUNT(CASE WHEN OVERALL_PASSED = TRUE THEN 1 END),
        COUNT(CASE WHEN OVERALL_PASSED = FALSE THEN 1 END)
    INTO :contracts_passed, :contracts_failed
    FROM GOVERNANCE.CONTRACTS.VALIDATION_HISTORY
    WHERE SOURCE_SYSTEM = 'WU'
      AND VALIDATION_START >= DATEADD('hour', -24, CURRENT_TIMESTAMP());

    RETURN OBJECT_CONSTRUCT(
        'timestamp', CURRENT_TIMESTAMP(),
        'tables', OBJECT_CONSTRUCT(
            'fact_transactions', OBJECT_CONSTRUCT('row_count', :txn_count, 'freshness_minutes', :txn_freshness),
            'dim_customer', OBJECT_CONSTRUCT('row_count', :cust_count),
            'dim_beneficiary', OBJECT_CONSTRUCT('row_count', :ben_count)
        ),
        'quality_scores', OBJECT_CONSTRUCT(
            'corridor_accuracy_pct', :corridor_accuracy,
            'customer_completeness_pct', :cust_completeness,
            'beneficiary_country_iso_pct', :ben_country_iso
        ),
        'quarantine', OBJECT_CONSTRUCT(
            'total_quarantined', :quarantine_total,
            'remediated', :quarantine_remediated,
            'remediation_rate_pct', :remediation_rate
        ),
        'contracts_24h', OBJECT_CONSTRUCT(
            'passed', :contracts_passed,
            'failed', :contracts_failed
        )
    );
END;

GRANT USAGE ON PROCEDURE CURATED_DEV.WU_KYC.SP_WU_REMEDIATE_COUNTRY_CODES() TO ROLE DATA_ENGINEER;
GRANT USAGE ON PROCEDURE CURATED_DEV.WU_KYC.SP_WU_REMEDIATE_PHONE_FORMAT() TO ROLE DATA_ENGINEER;
GRANT USAGE ON PROCEDURE CURATED_DEV.WU_KYC.SP_WU_QUALITY_DASHBOARD_DATA() TO ROLE DATA_ENGINEER;
GRANT USAGE ON PROCEDURE CURATED_DEV.WU_KYC.SP_WU_QUALITY_DASHBOARD_DATA() TO ROLE DATA_STEWARD;

-- ═══════════════════════════════════════════════════════════════════════════
-- VERIFICATION
-- ═══════════════════════════════════════════════════════════════════════════

-- Show DMFs attached to WU tables
SELECT
    METRIC_DATABASE_NAME || '.' || METRIC_SCHEMA_NAME || '.' || METRIC_NAME AS DMF,
    REF_DATABASE_NAME || '.' || REF_SCHEMA_NAME || '.' || REF_ENTITY_NAME AS TABLE_NAME,
    SCHEDULE_STATUS
FROM TABLE(INFORMATION_SCHEMA.DATA_METRIC_FUNCTION_REFERENCES(
    REF_ENTITY_NAME => 'CURATED_DEV.WU_PAYMENTS.FACT_TRANSACTIONS',
    REF_ENTITY_DOMAIN => 'TABLE'
));

SELECT '06_wu_quality_automation.sql completed successfully' AS STATUS;
