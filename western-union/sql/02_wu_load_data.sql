-- ============================================================================
-- WESTERN UNION — CDO ENGAGEMENT: DATA LOADING
-- ============================================================================
-- Scans WU folders on stage, infers schema, creates tables, loads data.
-- Wraps the same INFER_SCHEMA → CREATE → COPY pattern from SP_LOAD_DCIM_DATA.
--
-- STAGE PATH CONVENTION:
--   @RAW_DEV.STAGING.DATA_STAGE/wu_payments/*.csv
--   @RAW_DEV.STAGING.DATA_STAGE/wu_kyc/*.csv
--   @RAW_DEV.STAGING.DATA_STAGE/wu_compliance/*.csv
--
-- PREREQUISITES:
--   - sql/01_setup.sql executed (databases, roles exist)
--   - sql/03_raw_layer.sql executed (stage, formats exist)
--   - 01_wu_setup.sql executed (WU schemas exist)
--   - CSV files uploaded to stage (via PUT or deploy.sh)
--
-- RUN AS: DATA_ADMIN
-- ============================================================================

USE ROLE DATA_ADMIN;
USE DATABASE RAW_DEV;
USE WAREHOUSE INGEST_WH;

-- ═══════════════════════════════════════════════════════════════════════════
-- SP_LOAD_WU_DATA — Automated WU Loader
-- ═══════════════════════════════════════════════════════════════════════════
-- Scans WU folders on stage, infers schema, creates tables, loads data.
-- Wraps the same INFER_SCHEMA → CREATE → COPY pattern from SP_LOAD_DCIM_DATA.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE PROCEDURE RAW_DEV.STAGING.SP_LOAD_WU_DATA()
RETURNS VARIANT
LANGUAGE JAVASCRIPT
EXECUTE AS CALLER
AS
$$
    var results = [];

    // WU source systems → stage folder + schema + file format
    var wuSystems = [
        {schema: 'WU_PAYMENTS',    folder: 'wu_payments',    format: 'CSV'},
        {schema: 'WU_KYC',         folder: 'wu_kyc',         format: 'CSV'},
        {schema: 'WU_COMPLIANCE',  folder: 'wu_compliance',  format: 'CSV'}
    ];

    for (var s = 0; s < wuSystems.length; s++) {
        var sys = wuSystems[s];
        var schemaName = 'RAW_DEV.' + sys.schema;
        var fileExtension = sys.format === 'JSON' ? '.json' : '.csv';
        var inferFormat = sys.format === 'CSV'
            ? 'RAW_DEV.STAGING.CSV_INFER_FORMAT'
            : 'RAW_DEV.STAGING.' + sys.format + '_FORMAT';

        try {
            // List files in the folder
            var listSql = "LIST @RAW_DEV.STAGING.DATA_STAGE/" + sys.folder + "/";
            var listStmt = snowflake.createStatement({sqlText: listSql});
            var listResult = listStmt.execute();

            var files = [];
            while (listResult.next()) {
                var fullPath = listResult.getColumnValue(1);
                var lowerPath = fullPath.toLowerCase();
                if (lowerPath.endsWith(fileExtension) || lowerPath.endsWith(fileExtension + '.gz')) {
                    files.push(fullPath);
                }
            }

            if (files.length === 0) {
                results.push({
                    schema: sys.schema,
                    folder: sys.folder,
                    status: 'SKIPPED',
                    message: 'No ' + fileExtension + ' files found',
                    tables: 0,
                    rows: 0
                });
                continue;
            }

            var sysTablesLoaded = 0;
            var sysTablesFailed = 0;
            var sysTotalRows = 0;
            var sysDetails = [];

            for (var i = 0; i < files.length; i++) {
                var listedPath = files[i];
                var pathParts = listedPath.split('/');
                var fileNameWithExt = pathParts[pathParts.length - 1];

                // Derive table name from filename
                var tableName = fileNameWithExt
                    .replace(/\.gz$/i, '')
                    .replace(/\.(csv|json|parquet)$/i, '')
                    .toUpperCase();

                var stagePath = '@RAW_DEV.STAGING.DATA_STAGE/' + sys.folder + '/' + fileNameWithExt;
                var fullTableName = schemaName + '.' + tableName;

                try {
                    // Step 1: INFER_SCHEMA
                    var inferSql = "SELECT LISTAGG('\"' || COLUMN_NAME || '\" ' || TYPE, ', ') " +
                        "WITHIN GROUP (ORDER BY ORDER_ID) AS COL_DEFS " +
                        "FROM TABLE(INFER_SCHEMA(" +
                        "LOCATION => '" + stagePath + "', " +
                        "FILE_FORMAT => '" + inferFormat + "', " +
                        "MAX_RECORDS_PER_FILE => 1000))";

                    var inferStmt = snowflake.createStatement({sqlText: inferSql});
                    var inferResult = inferStmt.execute();

                    if (!inferResult.next()) {
                        sysDetails.push({table: tableName, status: 'ERROR', message: 'Infer failed', rows: 0});
                        sysTablesFailed++;
                        continue;
                    }

                    var columnDefs = inferResult.getColumnValue(1);
                    if (!columnDefs || columnDefs.trim() === '') {
                        sysDetails.push({table: tableName, status: 'ERROR', message: 'No columns', rows: 0});
                        sysTablesFailed++;
                        continue;
                    }

                    // Step 2: CREATE TABLE
                    var createSql = "CREATE OR REPLACE TABLE " + fullTableName + " (" + columnDefs + ") " +
                        "COMMENT = 'WU auto-loaded from " + fileNameWithExt + "'";
                    snowflake.createStatement({sqlText: createSql}).execute();

                    // Step 3: COPY INTO with MATCH_BY_COLUMN_NAME
                    var copySql = "COPY INTO " + fullTableName +
                        " FROM " + stagePath +
                        " FILE_FORMAT = " + inferFormat +
                        " MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE" +
                        " ON_ERROR = CONTINUE FORCE = TRUE";
                    snowflake.createStatement({sqlText: copySql}).execute();

                    // Step 4: Row count
                    var countSql = "SELECT COUNT(*) FROM " + fullTableName;
                    var countResult = snowflake.createStatement({sqlText: countSql}).execute();
                    countResult.next();
                    var rowCount = countResult.getColumnValue(1);

                    sysDetails.push({table: tableName, status: 'SUCCESS', rows: rowCount});
                    sysTablesLoaded++;
                    sysTotalRows += rowCount;

                } catch (fileErr) {
                    sysDetails.push({table: tableName, status: 'ERROR', message: fileErr.message, rows: 0});
                    sysTablesFailed++;
                }
            }

            results.push({
                schema: sys.schema,
                folder: sys.folder,
                status: sysTablesFailed === 0 ? 'SUCCESS' : 'PARTIAL',
                tables: sysTablesLoaded,
                failed: sysTablesFailed,
                rows: sysTotalRows,
                details: sysDetails
            });

        } catch (sysErr) {
            results.push({
                schema: sys.schema,
                folder: sys.folder,
                status: 'ERROR',
                message: sysErr.message,
                tables: 0,
                rows: 0
            });
        }
    }

    // Summary
    var totalTables = 0, totalRows = 0, totalFailed = 0;
    for (var r = 0; r < results.length; r++) {
        totalTables += results[r].tables || 0;
        totalRows   += results[r].rows   || 0;
        totalFailed += results[r].failed  || 0;
    }

    return {
        status: totalFailed === 0 && totalTables > 0 ? 'SUCCESS' :
                totalTables > 0 ? 'PARTIAL' : 'NO_DATA',
        total_tables: totalTables,
        total_failed: totalFailed,
        total_rows: totalRows,
        systems: results
    };
$$;

GRANT USAGE ON PROCEDURE RAW_DEV.STAGING.SP_LOAD_WU_DATA() TO ROLE DATA_ENGINEER;

-- ═══════════════════════════════════════════════════════════════════════════
-- MANUAL COPY INTO REFERENCE — All 9 WU Tables
-- ═══════════════════════════════════════════════════════════════════════════
-- Use these if you prefer explicit control over table creation and loading.
-- Each block: INFER → CREATE → COPY.
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── WU_PAYMENTS (3 tables) ───────────────────────────────────────────────

-- CALL RAW_DEV.STAGING.INFER_AND_CREATE_TABLE('WU_PAYMENTS', 'TRANSACTIONS',  'CSV', 'wu_payments/transactions.csv.gz');
-- CALL RAW_DEV.STAGING.INFER_AND_CREATE_TABLE('WU_PAYMENTS', 'CORRIDORS',     'CSV', 'wu_payments/corridors.csv.gz');
-- CALL RAW_DEV.STAGING.INFER_AND_CREATE_TABLE('WU_PAYMENTS', 'AGENTS',        'CSV', 'wu_payments/agents.csv.gz');

-- ─── WU_KYC (3 tables) ───────────────────────────────────────────────────

-- CALL RAW_DEV.STAGING.INFER_AND_CREATE_TABLE('WU_KYC', 'CUSTOMERS',      'CSV', 'wu_kyc/customers.csv.gz');
-- CALL RAW_DEV.STAGING.INFER_AND_CREATE_TABLE('WU_KYC', 'BENEFICIARIES',  'CSV', 'wu_kyc/beneficiaries.csv.gz');
-- CALL RAW_DEV.STAGING.INFER_AND_CREATE_TABLE('WU_KYC', 'DEVICES',        'CSV', 'wu_kyc/devices.csv.gz');

-- ─── WU_COMPLIANCE (3 tables) ────────────────────────────────────────────

-- CALL RAW_DEV.STAGING.INFER_AND_CREATE_TABLE('WU_COMPLIANCE', 'WATCHLIST_ENTITIES', 'CSV', 'wu_compliance/watchlist_entities.csv.gz');
-- CALL RAW_DEV.STAGING.INFER_AND_CREATE_TABLE('WU_COMPLIANCE', 'SARS',               'CSV', 'wu_compliance/sars.csv.gz');
-- CALL RAW_DEV.STAGING.INFER_AND_CREATE_TABLE('WU_COMPLIANCE', 'QUALITY_ISSUES',     'CSV', 'wu_compliance/quality_issues.csv.gz');

-- ═══════════════════════════════════════════════════════════════════════════
-- VERIFICATION QUERIES
-- ═══════════════════════════════════════════════════════════════════════════

-- WU table inventory
SELECT
    TABLE_SCHEMA  AS SOURCE_SYSTEM,
    TABLE_NAME,
    ROW_COUNT,
    CREATED       AS LOADED_AT
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_CATALOG = 'RAW_DEV'
  AND TABLE_SCHEMA IN ('WU_PAYMENTS', 'WU_KYC', 'WU_COMPLIANCE')
  AND TABLE_TYPE = 'BASE TABLE'
ORDER BY TABLE_SCHEMA, TABLE_NAME;

-- Row count summary by schema
SELECT
    TABLE_SCHEMA           AS SOURCE_SYSTEM,
    COUNT(*)               AS TABLE_COUNT,
    SUM(ROW_COUNT)         AS TOTAL_ROWS
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_CATALOG = 'RAW_DEV'
  AND TABLE_SCHEMA IN ('WU_PAYMENTS', 'WU_KYC', 'WU_COMPLIANCE')
  AND TABLE_TYPE = 'BASE TABLE'
GROUP BY TABLE_SCHEMA
ORDER BY TABLE_SCHEMA;

SELECT '02_wu_load_data.sql completed successfully' AS STATUS;
