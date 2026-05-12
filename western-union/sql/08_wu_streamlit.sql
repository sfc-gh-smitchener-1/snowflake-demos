-- ============================================================================
-- WESTERN UNION DEMO - Streamlit Deployment
-- ============================================================================
--
-- Deploys the WU Trust Dashboard as a Streamlit in Snowflake (SiS) app.
-- The app demonstrates role-switching governance: same data, different
-- answers per persona (Analyst / Compliance Officer / Executive).
--
-- Prerequisites: 01-07 scripts completed
-- RUN AS: DATA_ADMIN
-- ============================================================================

USE ROLE DATA_ADMIN;
USE DATABASE CURATED_DEV;
USE WAREHOUSE ANALYTICS_WH;

-- Deploy Streamlit app (placeholder for SiS deployment)
-- In production:
--   CREATE STREAMLIT CURATED_DEV.WU_PAYMENTS.WU_TRUST_DASHBOARD
--     ROOT_LOCATION = '@CURATED_DEV.WU_PAYMENTS.STREAMLIT_STAGE/wu_trust_dashboard'
--     MAIN_FILE = 'app.py'
--     QUERY_WAREHOUSE = 'ANALYTICS_WH';

SELECT 'Streamlit app ready for deployment. Run locally: streamlit run customer-demos/western-union/streamlit/app.py' AS STATUS;
