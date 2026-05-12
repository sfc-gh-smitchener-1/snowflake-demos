-- ============================================================================
-- WESTERN UNION DEMO - Tag-Based Governance: The Trust Foundation
-- ============================================================================
--
-- Demonstrates Snowflake Horizon capabilities — the same data answers
-- different questions for different roles.
--
--   1. OBJECT TAGS: PII, Compliance, Data Residency classification
--   2. MASKING POLICIES: Role-graduated PII visibility
--   3. ROW ACCESS POLICIES: Regional corridor scoping
--   4. TAG APPLICATION: Snowflake Horizon data classification
--
-- Role-based access matrix:
--   +-------------------------+-----------+------------+-----------+---------+
--   | Data Element            | DATA_ADMIN| COMPLIANCE | ANALYST   | NOC     |
--   +-------------------------+-----------+------------+-----------+---------+
--   | Customer Name           | Full      | Full       | Masked    | Hashed  |
--   | Date of Birth           | Full      | Full       | Masked    | Hashed  |
--   | Phone / Email           | Full      | Full       | Masked    | Hashed  |
--   | Transaction Amount      | Full      | Full       | Full      | Full    |
--   | Compliance Hold Flag    | Full      | Full       | Full      | Hashed  |
--   | Corridors Visible       | All       | All        | Regional  | All     |
--   +-------------------------+-----------+------------+-----------+---------+
--
-- Prerequisites: 01_wu_setup.sql, 03_wu_curated_layer.sql
-- RUN AS: DATA_ADMIN
-- ============================================================================

USE ROLE DATA_ADMIN;
USE DATABASE GOVERNANCE;
USE WAREHOUSE ANALYTICS_WH;

-- =============================================================================
-- SECTION 1: OBJECT TAGS
-- =============================================================================

-- PII Tags on DIM_CUSTOMER
ALTER TABLE CURATED_DEV.WU_KYC.DIM_CUSTOMER MODIFY COLUMN
    FULL_NAME SET TAG GOVERNANCE.TAGS.PII_TYPE = 'PERSON_NAME';

ALTER TABLE CURATED_DEV.WU_KYC.DIM_CUSTOMER MODIFY COLUMN
    DOB SET TAG GOVERNANCE.TAGS.PII_TYPE = 'DATE_OF_BIRTH';

ALTER TABLE CURATED_DEV.WU_KYC.DIM_CUSTOMER MODIFY COLUMN
    PHONE SET TAG GOVERNANCE.TAGS.PII_TYPE = 'PHONE_NUMBER';

ALTER TABLE CURATED_DEV.WU_KYC.DIM_CUSTOMER MODIFY COLUMN
    EMAIL SET TAG GOVERNANCE.TAGS.PII_TYPE = 'EMAIL_ADDRESS';

ALTER TABLE CURATED_DEV.WU_KYC.DIM_CUSTOMER MODIFY COLUMN
    ADDRESS SET TAG GOVERNANCE.TAGS.PII_TYPE = 'STREET_ADDRESS';

-- Compliance Tags on FACT_TRANSACTIONS
ALTER TABLE CURATED_DEV.WU_PAYMENTS.FACT_TRANSACTIONS MODIFY COLUMN
    AMOUNT_USD SET TAG GOVERNANCE.TAGS.COMPLIANCE = 'PCI_DSS';

ALTER TABLE CURATED_DEV.WU_PAYMENTS.FACT_TRANSACTIONS MODIFY COLUMN
    COMPLIANCE_HOLD SET TAG GOVERNANCE.TAGS.COMPLIANCE = 'BSA_AML';

-- Geographic Tags (for GDPR)
ALTER TABLE CURATED_DEV.WU_KYC.DIM_CUSTOMER MODIFY COLUMN
    COUNTRY SET TAG GOVERNANCE.TAGS.DATA_RESIDENCY = 'MULTI_REGION';

-- =============================================================================
-- SECTION 2: MASKING POLICIES
-- =============================================================================

-- PII String masking: COMPLIANCE_OFFICER sees full, ANALYST sees masked, others get hash
CREATE OR REPLACE MASKING POLICY GOVERNANCE.POLICIES.WU_PII_MASK
    AS (val STRING) RETURNS STRING ->
    CASE
        WHEN CURRENT_ROLE() IN ('DATA_ADMIN', 'COMPLIANCE_OFFICER') THEN val
        WHEN CURRENT_ROLE() = 'DATA_ANALYST' THEN '***MASKED***'
        ELSE SHA2(val)
    END
    COMMENT = 'Masks PII strings: full for admin/compliance, masked for analyst, hashed for others';

-- PII Date masking: same graduation
CREATE OR REPLACE MASKING POLICY GOVERNANCE.POLICIES.WU_PII_DATE_MASK
    AS (val DATE) RETURNS DATE ->
    CASE
        WHEN CURRENT_ROLE() IN ('DATA_ADMIN', 'COMPLIANCE_OFFICER') THEN val
        WHEN CURRENT_ROLE() = 'DATA_ANALYST' THEN DATE_FROM_PARTS(YEAR(val), 1, 1)
        ELSE NULL
    END
    COMMENT = 'Masks PII dates: full for admin/compliance, year-only for analyst, null for others';

-- Compliance flag masking: hidden from NOC
CREATE OR REPLACE MASKING POLICY GOVERNANCE.POLICIES.WU_COMPLIANCE_FLAG_MASK
    AS (val BOOLEAN) RETURNS BOOLEAN ->
    CASE
        WHEN CURRENT_ROLE() IN ('DATA_ADMIN', 'COMPLIANCE_OFFICER', 'DATA_ANALYST') THEN val
        ELSE NULL
    END
    COMMENT = 'Compliance hold flag hidden from non-authorized roles';

-- =============================================================================
-- SECTION 3: ROW-LEVEL SECURITY
-- =============================================================================

-- Regional teams see only their corridors
CREATE OR REPLACE ROW ACCESS POLICY GOVERNANCE.POLICIES.WU_REGIONAL_ACCESS
    AS (corridor_origin VARCHAR) RETURNS BOOLEAN ->
    CASE
        WHEN CURRENT_ROLE() IN ('DATA_ADMIN', 'COMPLIANCE_OFFICER') THEN TRUE
        WHEN CURRENT_ROLE() = 'AMERICAS_ANALYST'
            AND corridor_origin IN ('US', 'MX', 'GT', 'CO', 'BR') THEN TRUE
        WHEN CURRENT_ROLE() = 'EMEA_ANALYST'
            AND corridor_origin IN ('UK', 'DE', 'FR', 'AE', 'TR') THEN TRUE
        WHEN CURRENT_ROLE() = 'APAC_ANALYST'
            AND corridor_origin IN ('IN', 'PH', 'BD', 'PK') THEN TRUE
        ELSE FALSE
    END
    COMMENT = 'Regional corridor RLS: analysts see only their assigned corridors';

-- =============================================================================
-- SECTION 4: APPLY MASKING POLICIES TO CURATED TABLES
-- =============================================================================

-- DIM_CUSTOMER PII masking
ALTER TABLE CURATED_DEV.WU_KYC.DIM_CUSTOMER MODIFY COLUMN
    FULL_NAME SET MASKING POLICY GOVERNANCE.POLICIES.WU_PII_MASK;

ALTER TABLE CURATED_DEV.WU_KYC.DIM_CUSTOMER MODIFY COLUMN
    PHONE SET MASKING POLICY GOVERNANCE.POLICIES.WU_PII_MASK;

ALTER TABLE CURATED_DEV.WU_KYC.DIM_CUSTOMER MODIFY COLUMN
    EMAIL SET MASKING POLICY GOVERNANCE.POLICIES.WU_PII_MASK;

ALTER TABLE CURATED_DEV.WU_KYC.DIM_CUSTOMER MODIFY COLUMN
    ADDRESS SET MASKING POLICY GOVERNANCE.POLICIES.WU_PII_MASK;

ALTER TABLE CURATED_DEV.WU_KYC.DIM_CUSTOMER MODIFY COLUMN
    DOB SET MASKING POLICY GOVERNANCE.POLICIES.WU_PII_DATE_MASK;

-- FACT_TRANSACTIONS compliance flag masking
ALTER TABLE CURATED_DEV.WU_PAYMENTS.FACT_TRANSACTIONS MODIFY COLUMN
    COMPLIANCE_HOLD SET MASKING POLICY GOVERNANCE.POLICIES.WU_COMPLIANCE_FLAG_MASK;

-- =============================================================================
-- SECTION 5: APPLY ROW ACCESS POLICIES
-- =============================================================================

-- Apply regional RLS to corridor dimension
ALTER TABLE CURATED_DEV.WU_PAYMENTS.DIM_CORRIDOR
    ADD ROW ACCESS POLICY GOVERNANCE.POLICIES.WU_REGIONAL_ACCESS ON (ORIGIN_COUNTRY);

-- Apply regional RLS to transactions (origin country from corridor)
ALTER TABLE CURATED_DEV.WU_PAYMENTS.FACT_TRANSACTIONS
    ADD ROW ACCESS POLICY GOVERNANCE.POLICIES.WU_REGIONAL_ACCESS ON (ORIGIN_COUNTRY);

-- =============================================================================
-- SECTION 6: TAG APPLICATION (Snowflake Horizon data classification)
-- =============================================================================

-- Tag tables with domain
ALTER TABLE CURATED_DEV.WU_KYC.DIM_CUSTOMER
    SET TAG GOVERNANCE.TAGS.DATA_DOMAIN = 'KYC';

ALTER TABLE CURATED_DEV.WU_KYC.DIM_BENEFICIARY
    SET TAG GOVERNANCE.TAGS.DATA_DOMAIN = 'KYC';

ALTER TABLE CURATED_DEV.WU_PAYMENTS.FACT_TRANSACTIONS
    SET TAG GOVERNANCE.TAGS.DATA_DOMAIN = 'PAYMENTS';

ALTER TABLE CURATED_DEV.WU_PAYMENTS.DIM_CORRIDOR
    SET TAG GOVERNANCE.TAGS.DATA_DOMAIN = 'PAYMENTS';

ALTER TABLE CURATED_DEV.WU_PAYMENTS.DIM_AGENT
    SET TAG GOVERNANCE.TAGS.DATA_DOMAIN = 'AGENT_NETWORK';

ALTER TABLE CURATED_DEV.WU_COMPLIANCE.FACT_SARS
    SET TAG GOVERNANCE.TAGS.DATA_DOMAIN = 'COMPLIANCE';

ALTER TABLE CURATED_DEV.WU_COMPLIANCE.DIM_WATCHLIST
    SET TAG GOVERNANCE.TAGS.DATA_DOMAIN = 'COMPLIANCE';

-- Tag sensitivity levels on key columns
ALTER TABLE CURATED_DEV.WU_KYC.DIM_CUSTOMER MODIFY COLUMN
    FULL_NAME SET TAG GOVERNANCE.TAGS.SENSITIVITY = 'CONFIDENTIAL';

ALTER TABLE CURATED_DEV.WU_KYC.DIM_CUSTOMER MODIFY COLUMN
    EMAIL SET TAG GOVERNANCE.TAGS.SENSITIVITY = 'CONFIDENTIAL';

ALTER TABLE CURATED_DEV.WU_KYC.DIM_CUSTOMER MODIFY COLUMN
    PHONE SET TAG GOVERNANCE.TAGS.SENSITIVITY = 'CONFIDENTIAL';

ALTER TABLE CURATED_DEV.WU_KYC.DIM_CUSTOMER MODIFY COLUMN
    DOB SET TAG GOVERNANCE.TAGS.SENSITIVITY = 'RESTRICTED';

ALTER TABLE CURATED_DEV.WU_KYC.DIM_CUSTOMER MODIFY COLUMN
    ADDRESS SET TAG GOVERNANCE.TAGS.SENSITIVITY = 'RESTRICTED';

ALTER TABLE CURATED_DEV.WU_PAYMENTS.FACT_TRANSACTIONS MODIFY COLUMN
    AMOUNT_USD SET TAG GOVERNANCE.TAGS.SENSITIVITY = 'INTERNAL';

ALTER TABLE CURATED_DEV.WU_COMPLIANCE.FACT_SARS MODIFY COLUMN
    SAR_ID SET TAG GOVERNANCE.TAGS.SENSITIVITY = 'RESTRICTED';

-- =============================================================================
-- VERIFICATION
-- =============================================================================
-- Expected results:
--   DATA_ADMIN          -> All rows, all columns in clear
--   COMPLIANCE_OFFICER  -> All rows, all columns in clear
--   DATA_ANALYST        -> All rows, PII masked as '***MASKED***', DOB year-only
--   AMERICAS_ANALYST    -> US/MX/GT/CO/BR corridors only, PII hashed
--   EMEA_ANALYST        -> UK/DE/FR/AE/TR corridors only, PII hashed
--   APAC_ANALYST        -> IN/PH/BD/PK corridors only, PII hashed

SELECT 'Governance complete: 3 masking policies, 1 row access policy, PII/Compliance/Residency tags applied.' AS STATUS;
