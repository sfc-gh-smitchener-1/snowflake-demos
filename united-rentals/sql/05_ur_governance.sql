-- ============================================================================
-- UNITED RENTALS DEMO - Governance: Masking, Row Access, Tags
-- ============================================================================
--
-- Demonstrates Snowflake Horizon governance capabilities:
--   1. MASKING POLICIES: Customer PII + rental pricing graduated by role
--   2. ROW ACCESS POLICIES: Region/branch-scoped data per role
--   3. TAG APPLICATION: Data classification on sensitive columns
--
-- Role-based access matrix:
--   ┌─────────────────────────┬──────────┬─────────┬────────┬──────┬────────┐
--   │ Data Element            │ Fleet Mgr│ Reg Dir │ Br Mgr │ Corp │ Extern │
--   ├─────────────────────────┼──────────┼─────────┼────────┼──────┼────────┤
--   │ Customer Name           │ Full     │ Full    │ Full   │ Mask │ Mask   │
--   │ Customer Email          │ Full     │ Full    │ Full   │ Mask │ Mask   │
--   │ Customer Phone          │ Full     │ Full    │ Full   │ Mask │ Mask   │
--   │ Rental Rates            │ Full     │ Full    │ Full   │ Full │ Hidden │
--   │ Regions Visible         │ All      │ Assign  │ Assign │ All  │ Assign │
--   │ Branches Visible        │ All      │ Region  │ 1 Only │ All  │ Region │
--   │ View-Level RLS          │ Yes      │ Yes     │ Yes    │ Yes  │ Yes    │
--   └─────────────────────────┴──────────┴─────────┴────────┴──────┴────────┘
--
-- Prerequisites: 01_ur_setup.sql, 03_ur_curated_layer.sql
-- RUN AS: DATA_ADMIN
-- ============================================================================

USE ROLE DATA_ADMIN;
USE DATABASE CURATED_DEV;
USE SCHEMA CURATED_DEV.UNITED_RENTALS;
USE WAREHOUSE ANALYTICS_WH;

-- ═══════════════════════════════════════════════════════════════════════════
-- MASKING POLICIES
-- ═══════════════════════════════════════════════════════════════════════════

-- Customer Name: Masked for Corporate Analyst and External Partner
CREATE OR REPLACE MASKING POLICY CURATED_DEV.UNITED_RENTALS.MASK_UR_CUSTOMER_NAME
    AS (val STRING) RETURNS STRING ->
    CASE
        WHEN CURRENT_ROLE() IN ('DATA_ADMIN', 'UR_FLEET_MANAGER', 'UR_REGIONAL_DIRECTOR', 'UR_BRANCH_MANAGER')
            THEN val
        WHEN CURRENT_ROLE() = 'UR_CORPORATE_ANALYST'
            THEN CONCAT(LEFT(val, 3), '***')
        ELSE '*** RESTRICTED ***'
    END
    COMMENT = 'Masks customer company name based on UR role hierarchy';

-- Customer Email: Masked for analysts, hidden for external
CREATE OR REPLACE MASKING POLICY CURATED_DEV.UNITED_RENTALS.MASK_UR_EMAIL
    AS (val STRING) RETURNS STRING ->
    CASE
        WHEN CURRENT_ROLE() IN ('DATA_ADMIN', 'UR_FLEET_MANAGER', 'UR_REGIONAL_DIRECTOR', 'UR_BRANCH_MANAGER')
            THEN val
        WHEN CURRENT_ROLE() = 'UR_CORPORATE_ANALYST'
            THEN CONCAT('***@', SPLIT_PART(val, '@', 2))
        ELSE '***@***.***'
    END
    COMMENT = 'Masks customer email - partial for analysts, full for external';

-- Customer Phone: Masked for analysts, hidden for external
CREATE OR REPLACE MASKING POLICY CURATED_DEV.UNITED_RENTALS.MASK_UR_PHONE
    AS (val STRING) RETURNS STRING ->
    CASE
        WHEN CURRENT_ROLE() IN ('DATA_ADMIN', 'UR_FLEET_MANAGER', 'UR_REGIONAL_DIRECTOR', 'UR_BRANCH_MANAGER')
            THEN val
        WHEN CURRENT_ROLE() = 'UR_CORPORATE_ANALYST'
            THEN CONCAT('***-***-', RIGHT(val, 4))
        ELSE '***-***-****'
    END
    COMMENT = 'Masks customer phone - last 4 digits for analysts, full mask for external';

-- Rental Rate: Hidden for external partners
CREATE OR REPLACE MASKING POLICY CURATED_DEV.UNITED_RENTALS.MASK_UR_RATE
    AS (val FLOAT) RETURNS FLOAT ->
    CASE
        WHEN CURRENT_ROLE() IN ('DATA_ADMIN', 'UR_FLEET_MANAGER', 'UR_REGIONAL_DIRECTOR',
                                 'UR_BRANCH_MANAGER', 'UR_CORPORATE_ANALYST')
            THEN val
        ELSE NULL
    END
    COMMENT = 'Hides rental pricing from external partners';

-- Credit Limit: Only visible to fleet manager and admin
CREATE OR REPLACE MASKING POLICY CURATED_DEV.UNITED_RENTALS.MASK_UR_CREDIT
    AS (val FLOAT) RETURNS FLOAT ->
    CASE
        WHEN CURRENT_ROLE() IN ('DATA_ADMIN', 'UR_FLEET_MANAGER')
            THEN val
        ELSE NULL
    END
    COMMENT = 'Credit limit visible only to fleet manager and admin';

-- ═══════════════════════════════════════════════════════════════════════════
-- ROW ACCESS POLICY (region/branch scoping)
-- ═══════════════════════════════════════════════════════════════════════════

-- Row access based on region mapping table (for direct table access)
CREATE OR REPLACE ROW ACCESS POLICY CURATED_DEV.UNITED_RENTALS.RAP_UR_REGION
    AS (region_val VARCHAR) RETURNS BOOLEAN ->
    CASE
        -- Admin always sees everything
        WHEN CURRENT_ROLE() = 'DATA_ADMIN' THEN TRUE
        -- Check role-region mapping
        WHEN EXISTS (
            SELECT 1 FROM CURATED_DEV.UNITED_RENTALS.ROLE_REGION_MAPPING
            WHERE ROLE_NAME = CURRENT_ROLE()
              AND REGION = region_val
        ) THEN TRUE
        ELSE FALSE
    END
    COMMENT = 'Restricts row visibility by region based on role-region mapping table';

-- ─────────────────────────────────────────────────────────────────────────────
-- VIEW-LEVEL ROW ACCESS POLICY (region + branch scoping)
-- ─────────────────────────────────────────────────────────────────────────────
-- IMPORTANT: RLS policies on underlying tables evaluate with the VIEW OWNER's
-- role context (DATA_ADMIN), which bypasses the admin check. To enforce RLS
-- through views, the policy must be applied directly to the VIEW.
--
-- RAP_FLEET_VIEW uses two columns: REGION (region scoping) and BRANCH_ID
-- (branch-level scoping for UR_BRANCH_MANAGER). The mapping table controls:
--   - BRANCH_ID = NULL  → role sees ALL branches in that region
--   - BRANCH_ID = value → role sees ONLY that specific branch
CREATE OR REPLACE ROW ACCESS POLICY CURATED_DEV.UNITED_RENTALS.RAP_FLEET_VIEW
    AS (region_val VARCHAR, branch_id_val VARCHAR) RETURNS BOOLEAN ->
    CASE
        WHEN CURRENT_ROLE() = 'DATA_ADMIN' THEN TRUE
        WHEN EXISTS (
            SELECT 1 FROM CURATED_DEV.UNITED_RENTALS.ROLE_REGION_MAPPING
            WHERE ROLE_NAME = CURRENT_ROLE()
              AND REGION = region_val
              AND (BRANCH_ID IS NULL OR BRANCH_ID = branch_id_val)
        ) THEN TRUE
        ELSE FALSE
    END
    COMMENT = 'View-level RLS: region + branch scoping via ROLE_REGION_MAPPING';

-- ═══════════════════════════════════════════════════════════════════════════
-- APPLY MASKING POLICIES TO CURATED TABLES
-- ═══════════════════════════════════════════════════════════════════════════

-- DIM_CUSTOMER masking
ALTER TABLE CURATED_DEV.UNITED_RENTALS.DIM_CUSTOMER MODIFY COLUMN
    COMPANY_NAME SET MASKING POLICY CURATED_DEV.UNITED_RENTALS.MASK_UR_CUSTOMER_NAME;

ALTER TABLE CURATED_DEV.UNITED_RENTALS.DIM_CUSTOMER MODIFY COLUMN
    EMAIL SET MASKING POLICY CURATED_DEV.UNITED_RENTALS.MASK_UR_EMAIL;

ALTER TABLE CURATED_DEV.UNITED_RENTALS.DIM_CUSTOMER MODIFY COLUMN
    PHONE SET MASKING POLICY CURATED_DEV.UNITED_RENTALS.MASK_UR_PHONE;

ALTER TABLE CURATED_DEV.UNITED_RENTALS.DIM_CUSTOMER MODIFY COLUMN
    CREDIT_LIMIT SET MASKING POLICY CURATED_DEV.UNITED_RENTALS.MASK_UR_CREDIT;

-- DIM_EQUIPMENT rate masking
ALTER TABLE CURATED_DEV.UNITED_RENTALS.DIM_EQUIPMENT MODIFY COLUMN
    DAILY_RATE SET MASKING POLICY CURATED_DEV.UNITED_RENTALS.MASK_UR_RATE;

ALTER TABLE CURATED_DEV.UNITED_RENTALS.DIM_EQUIPMENT MODIFY COLUMN
    WEEKLY_RATE SET MASKING POLICY CURATED_DEV.UNITED_RENTALS.MASK_UR_RATE;

ALTER TABLE CURATED_DEV.UNITED_RENTALS.DIM_EQUIPMENT MODIFY COLUMN
    MONTHLY_RATE SET MASKING POLICY CURATED_DEV.UNITED_RENTALS.MASK_UR_RATE;

-- FACT_RENTALS rate and customer masking
ALTER TABLE CURATED_DEV.UNITED_RENTALS.FACT_RENTALS MODIFY COLUMN
    DAILY_RATE SET MASKING POLICY CURATED_DEV.UNITED_RENTALS.MASK_UR_RATE;

ALTER TABLE CURATED_DEV.UNITED_RENTALS.FACT_RENTALS MODIFY COLUMN
    TOTAL_AMOUNT SET MASKING POLICY CURATED_DEV.UNITED_RENTALS.MASK_UR_RATE;

ALTER TABLE CURATED_DEV.UNITED_RENTALS.FACT_RENTALS MODIFY COLUMN
    CUSTOMER_NAME SET MASKING POLICY CURATED_DEV.UNITED_RENTALS.MASK_UR_CUSTOMER_NAME;

-- ═══════════════════════════════════════════════════════════════════════════
-- APPLY ROW ACCESS POLICIES
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE CURATED_DEV.UNITED_RENTALS.DIM_BRANCH
    ADD ROW ACCESS POLICY CURATED_DEV.UNITED_RENTALS.RAP_UR_REGION ON (REGION);

-- Note: DIM_EQUIPMENT inherits region filtering through FLEET_AVAILABILITY view
-- which joins to DIM_BRANCH (where the RAP is applied). The join naturally
-- filters equipment to only visible branches. We also apply the RAP directly
-- on FACT_RENTALS which carries the REGION column from the branch join.

ALTER TABLE CURATED_DEV.UNITED_RENTALS.FACT_RENTALS
    ADD ROW ACCESS POLICY CURATED_DEV.UNITED_RENTALS.RAP_UR_REGION ON (REGION);

ALTER TABLE CURATED_DEV.UNITED_RENTALS.FACT_MAINTENANCE
    ADD ROW ACCESS POLICY CURATED_DEV.UNITED_RENTALS.RAP_UR_REGION ON (REGION);

-- ═══════════════════════════════════════════════════════════════════════════
-- TAG APPLICATION (Snowflake Horizon data classification)
-- ═══════════════════════════════════════════════════════════════════════════

-- Tag the customer table with domain and sensitivity
ALTER TABLE CURATED_DEV.UNITED_RENTALS.DIM_CUSTOMER
    SET TAG GOVERNANCE.TAGS.UR_DATA_DOMAIN = 'CUSTOMER';

ALTER TABLE CURATED_DEV.UNITED_RENTALS.DIM_CUSTOMER MODIFY COLUMN
    COMPANY_NAME SET TAG GOVERNANCE.TAGS.UR_SENSITIVITY = 'INTERNAL';

ALTER TABLE CURATED_DEV.UNITED_RENTALS.DIM_CUSTOMER MODIFY COLUMN
    EMAIL SET TAG GOVERNANCE.TAGS.UR_SENSITIVITY = 'CONFIDENTIAL';

ALTER TABLE CURATED_DEV.UNITED_RENTALS.DIM_CUSTOMER MODIFY COLUMN
    PHONE SET TAG GOVERNANCE.TAGS.UR_SENSITIVITY = 'CONFIDENTIAL';

ALTER TABLE CURATED_DEV.UNITED_RENTALS.DIM_CUSTOMER MODIFY COLUMN
    CREDIT_LIMIT SET TAG GOVERNANCE.TAGS.UR_SENSITIVITY = 'RESTRICTED';

-- Tag equipment and rentals
ALTER TABLE CURATED_DEV.UNITED_RENTALS.DIM_EQUIPMENT
    SET TAG GOVERNANCE.TAGS.UR_DATA_DOMAIN = 'FLEET';

ALTER TABLE CURATED_DEV.UNITED_RENTALS.DIM_EQUIPMENT MODIFY COLUMN
    DAILY_RATE SET TAG GOVERNANCE.TAGS.UR_SENSITIVITY = 'INTERNAL';

ALTER TABLE CURATED_DEV.UNITED_RENTALS.FACT_RENTALS
    SET TAG GOVERNANCE.TAGS.UR_DATA_DOMAIN = 'RENTAL';

ALTER TABLE CURATED_DEV.UNITED_RENTALS.FACT_RENTALS MODIFY COLUMN
    TOTAL_AMOUNT SET TAG GOVERNANCE.TAGS.UR_SENSITIVITY = 'CONFIDENTIAL';

ALTER TABLE CURATED_DEV.UNITED_RENTALS.FACT_TELEMATICS_LATEST
    SET TAG GOVERNANCE.TAGS.UR_DATA_DOMAIN = 'TELEMATICS';

-- ═══════════════════════════════════════════════════════════════════════════
-- "AND WORLD" RBAC PATTERN
-- ═══════════════════════════════════════════════════════════════════════════
-- UR needs RBAC that facilitates an "AND" world:
--   Shared spaces AND locked-down department spaces AND user-only spaces
--
-- This maps to Snowflake's layered security model:
--   SHARED   = Views/tables granted to all UR roles (fleet availability)
--   DEPT     = Schema-level grants scoped by department (regional data)
--   PRIVATE  = Row-access + masking policies for individual user context
--
-- The combination of:
--   1. Role hierarchy (UR_FLEET_MANAGER > UR_REGIONAL_DIRECTOR > UR_BRANCH_MANAGER)
--   2. Row access policies (region/branch scoping via ROLE_REGION_MAPPING table)
--   3. Column masking policies (PII and pricing graduated by role)
-- Creates the AND world: each user sees shared + their department + their own scope.

-- Demonstrate the AND world with a verification query:
-- Run this as each role to see the graduated access in action.

-- SHARED: All roles see the fleet availability view (with role-appropriate filtering)
GRANT SELECT ON VIEW CURATED_DEV.UNITED_RENTALS.FLEET_AVAILABILITY TO ROLE UR_FLEET_MANAGER;
GRANT SELECT ON VIEW CURATED_DEV.UNITED_RENTALS.FLEET_AVAILABILITY TO ROLE UR_EXTERNAL_PARTNER;

-- DEPARTMENT: Regional/branch scoping enforced by row access policies above

-- PRIVATE: Masking policies above enforce per-role column visibility

-- ═══════════════════════════════════════════════════════════════════════════
-- RLS FRAMEWORK VARIANTS (Location, Customer, Geography)
-- ═══════════════════════════════════════════════════════════════════════════
-- UR needs different RLS frameworks for different dimensions:
--   1. Location-based RLS  → RAP_UR_REGION (above) — branch/region scoping
--   2. Customer-based RLS  → RAP_UR_CUSTOMER (below) — customer visibility
--   3. Geography-based RLS → Covered by region policy + ST_DISTANCE in app layer

-- Customer-scoped row access: external partners only see their own contracts
CREATE OR REPLACE ROW ACCESS POLICY CURATED_DEV.UNITED_RENTALS.RAP_UR_CUSTOMER
    AS (customer_type_val VARCHAR) RETURNS BOOLEAN ->
    CASE
        -- Internal roles see all customers
        WHEN CURRENT_ROLE() IN ('DATA_ADMIN', 'UR_FLEET_MANAGER', 'UR_REGIONAL_DIRECTOR',
                                 'UR_BRANCH_MANAGER', 'UR_CORPORATE_ANALYST')
            THEN TRUE
        -- External partners only see CONSTRUCTION and INFRASTRUCTURE customers (public sector)
        WHEN CURRENT_ROLE() = 'UR_EXTERNAL_PARTNER'
            AND customer_type_val IN ('CONSTRUCTION', 'INFRASTRUCTURE', 'GOVERNMENT')
            THEN TRUE
        ELSE FALSE
    END
    COMMENT = 'Customer-type RLS: external partners see only construction/infrastructure/government';

ALTER TABLE CURATED_DEV.UNITED_RENTALS.DIM_CUSTOMER
    ADD ROW ACCESS POLICY CURATED_DEV.UNITED_RENTALS.RAP_UR_CUSTOMER ON (CUSTOMER_TYPE);

-- ═══════════════════════════════════════════════════════════════════════════
-- SSO + EXTERNAL ACCESS READINESS
-- ═══════════════════════════════════════════════════════════════════════════
-- UR context: Discovery has SSO, EDW accounts do not.
-- This section demonstrates the governance objects that work identically
-- whether the user authenticates via SSO (Discovery) or local auth (EDW).
-- Policies are attached to objects, not users — so the same masking/RLS
-- works across all accounts once the role hierarchy is replicated.
--
-- When UR unifies SSO across accounts, these policies will automatically
-- enforce the correct access for every user — no policy migration needed.
--
-- The ROLE_REGION_MAPPING table is the single source of truth for
-- role-to-region assignments. Updating one row changes access for
-- every table that uses RAP_UR_REGION — no per-table edits required.

-- ═══════════════════════════════════════════════════════════════════════════
-- SECURE VIEW + VIEW-LEVEL RLS
-- ═══════════════════════════════════════════════════════════════════════════
-- FLEET_AVAILABILITY must be a SECURE VIEW so that:
--   1. The view definition is hidden from non-owner roles
--   2. The query optimizer cannot push predicates through (prevents data leakage)
--
-- The view-level RAP_FLEET_VIEW policy is applied ON the view itself because
-- table-level policies (RAP_UR_REGION on DIM_BRANCH) evaluate with the VIEW
-- OWNER's context (DATA_ADMIN) when accessed through a view. Applying the
-- policy to the view ensures CURRENT_ROLE() returns the caller's actual role.

ALTER VIEW CURATED_DEV.UNITED_RENTALS.FLEET_AVAILABILITY SET SECURE;

ALTER VIEW CURATED_DEV.UNITED_RENTALS.FLEET_AVAILABILITY
    ADD ROW ACCESS POLICY CURATED_DEV.UNITED_RENTALS.RAP_FLEET_VIEW ON (REGION, BRANCH_ID);

-- ═══════════════════════════════════════════════════════════════════════════
-- FIX ROLE_REGION_MAPPING DATA
-- ═══════════════════════════════════════════════════════════════════════════
-- UR_BRANCH_MANAGER is mapped to SOUTHWEST + BR-01069 (Dallas #1).
-- The BRANCH_ID must match an actual branch in the SOUTHWEST region.
UPDATE CURATED_DEV.UNITED_RENTALS.ROLE_REGION_MAPPING
SET BRANCH_ID = 'BR-01069'
WHERE ROLE_NAME = 'UR_BRANCH_MANAGER' AND REGION = 'SOUTHWEST' AND BRANCH_ID != 'BR-01069';

-- ═══════════════════════════════════════════════════════════════════════════
-- VERIFICATION
-- ═══════════════════════════════════════════════════════════════════════════
-- Expected results through FLEET_AVAILABILITY (SECURE VIEW + RAP_FLEET_VIEW):
--   UR_FLEET_MANAGER     → 5000 rows, 5 regions, 100 branches (full access)
--   UR_CORPORATE_ANALYST → 5000 rows, 5 regions, 100 branches (rates visible, PII masked)
--   UR_REGIONAL_DIRECTOR →  723 rows, 1 region,   14 branches (SOUTHWEST only)
--   UR_BRANCH_MANAGER    →   60 rows, 1 region,    1 branch  (BR-01069 Dallas #1)
--   UR_EXTERNAL_PARTNER  →  723 rows, 1 region,   14 branches (SOUTHWEST, rates masked)

SELECT 'Governance complete: 5 masking policies, 3 row access policies (incl. view-level), SECURE VIEW, AND-world RBAC, tags applied.' AS STATUS;
