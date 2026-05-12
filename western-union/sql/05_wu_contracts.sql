-- ============================================================================
-- WESTERN UNION — DATA CONTRACTS: Schema + Quality + SLA as One Agreement
-- ============================================================================
-- This script proves that the semantic schema and the quality gate are the
-- SAME thing. Contracts attach to curated tables; violations quarantine data
-- before it reaches the semantic layer.
--
-- Uses the CONTRACT_REGISTRY, QUALITY_RULES, and SLA_DEFINITIONS tables
-- from sql/08_contracts.sql.
--
-- PREREQUISITES:
--   - sql/08_contracts.sql executed (GOVERNANCE.CONTRACTS schema + tables)
--   - 03_wu_curated_layer.sql executed (CURATED_DEV Dynamic Tables)
--
-- RUN AS: DATA_ADMIN
-- ============================================================================

USE ROLE DATA_ADMIN;
USE DATABASE GOVERNANCE;
USE SCHEMA GOVERNANCE.CONTRACTS;
USE WAREHOUSE TRANSFORM_WH;

-- ═══════════════════════════════════════════════════════════════════════════
-- QUARANTINE TABLE — Records that fail contract validation
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS GOVERNANCE.CONTRACTS.WU_QUARANTINE (
    QUARANTINE_ID       VARCHAR DEFAULT UUID_STRING(),
    SOURCE_TABLE        VARCHAR,
    RECORD_ID           VARCHAR,
    RULE_ID             VARCHAR,
    RULE_NAME           VARCHAR,
    VIOLATION_DETAILS   VARIANT,
    QUARANTINED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    REMEDIATED          BOOLEAN DEFAULT FALSE,
    REMEDIATED_AT       TIMESTAMP_NTZ,
    REMEDIATION_METHOD  VARCHAR
);

-- ═══════════════════════════════════════════════════════════════════════════
-- CONTRACT 1: WU_PAYMENTS.FACT_TRANSACTIONS
-- ═══════════════════════════════════════════════════════════════════════════

-- Register the contract
MERGE INTO CONTRACT_REGISTRY tgt
USING (
    SELECT
        'CONTRACT-WU_PAYMENTS-FACT_TRANSACTIONS-001' AS CONTRACT_ID,
        'WU Payments FACT_TRANSACTIONS Data Contract' AS CONTRACT_NAME,
        '1.0' AS CONTRACT_VERSION,
        'ACTIVE' AS CONTRACT_STATUS,
        'WU_PAYMENTS' AS SOURCE_SYSTEM,
        'FACT_TRANSACTIONS' AS SOURCE_TABLE,
        'CURATED_DEV.WU_PAYMENTS.FACT_TRANSACTIONS' AS FULL_TABLE_PATH,
        'WU Data Engineering' AS PRODUCER_TEAM,
        'data-eng@westernunion.com' AS PRODUCER_OWNER_EMAIL,
        PARSE_JSON('["WU Compliance","WU Analytics","CDO Office"]') AS CONSUMER_TEAMS,
        PARSE_JSON('{
            "required_columns": ["TRANSACTION_ID","AMOUNT_USD","CORRIDOR","STATUS","CREATED_AT"],
            "not_null": ["TRANSACTION_ID","CORRIDOR"],
            "check_constraints": {"AMOUNT_USD": "> 0", "STATUS": "IN (''COMPLETED'',''PENDING'',''FAILED'',''HELD'')"}
        }') AS SCHEMA_DEFINITION,
        PARSE_JSON('{
            "rules": ["WU_TXN_AMOUNT_POSITIVE","WU_TXN_CORRIDOR_NOT_NULL","WU_TXN_STATUS_VALID","WU_TXN_NO_STRUCTURING"]
        }') AS QUALITY_DEFINITION,
        PARSE_JSON('{
            "freshness_minutes": 5,
            "availability_pct": 99.9
        }') AS SLA_DEFINITION,
        PARSE_JSON('{
            "classification": "CONFIDENTIAL",
            "retention_days": 2555,
            "pii_columns": ["SENDER_ID","RECEIVER_ID"]
        }') AS GOVERNANCE_DEFINITION,
        'Core transaction fact table — every remittance flows through here' AS DESCRIPTION
) src ON tgt.CONTRACT_ID = src.CONTRACT_ID
WHEN MATCHED THEN UPDATE SET
    CONTRACT_NAME = src.CONTRACT_NAME,
    CONTRACT_VERSION = src.CONTRACT_VERSION,
    UPDATED_AT = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
    CONTRACT_ID, CONTRACT_NAME, CONTRACT_VERSION, CONTRACT_STATUS,
    SOURCE_SYSTEM, SOURCE_TABLE, FULL_TABLE_PATH,
    PRODUCER_TEAM, PRODUCER_OWNER_EMAIL, CONSUMER_TEAMS,
    SCHEMA_DEFINITION, QUALITY_DEFINITION, SLA_DEFINITION, GOVERNANCE_DEFINITION,
    DESCRIPTION
) VALUES (
    src.CONTRACT_ID, src.CONTRACT_NAME, src.CONTRACT_VERSION, src.CONTRACT_STATUS,
    src.SOURCE_SYSTEM, src.SOURCE_TABLE, src.FULL_TABLE_PATH,
    src.PRODUCER_TEAM, src.PRODUCER_OWNER_EMAIL, src.CONSUMER_TEAMS,
    src.SCHEMA_DEFINITION, src.QUALITY_DEFINITION, src.SLA_DEFINITION, src.GOVERNANCE_DEFINITION,
    src.DESCRIPTION
);

-- Quality rules for FACT_TRANSACTIONS
MERGE INTO QUALITY_RULES tgt USING (
    SELECT * FROM VALUES
    ('WU-QR-TXN-001', 'CONTRACT-WU_PAYMENTS-FACT_TRANSACTIONS-001', 'WU_PAYMENTS',
     'WU_TXN_AMOUNT_POSITIVE', 'Transaction amount must be positive',
     'AMOUNT_USD > 0', 'ROW', 100.0, NULL, 'ERROR', 'BLOCK', TRUE),
    ('WU-QR-TXN-002', 'CONTRACT-WU_PAYMENTS-FACT_TRANSACTIONS-001', 'WU_PAYMENTS',
     'WU_TXN_CORRIDOR_NOT_NULL', 'Corridor must not be null',
     'CORRIDOR IS NOT NULL', 'ROW', 100.0, NULL, 'ERROR', 'BLOCK', TRUE),
    ('WU-QR-TXN-003', 'CONTRACT-WU_PAYMENTS-FACT_TRANSACTIONS-001', 'WU_PAYMENTS',
     'WU_TXN_STATUS_VALID', 'Status must be a valid enum value',
     'STATUS IN (''COMPLETED'',''PENDING'',''FAILED'',''HELD'')', 'ROW', 100.0, 95.0, 'WARNING', 'ALERT', TRUE),
    ('WU-QR-TXN-004', 'CONTRACT-WU_PAYMENTS-FACT_TRANSACTIONS-001', 'WU_PAYMENTS',
     'WU_TXN_NO_STRUCTURING', 'Flag structuring: 3+ txns from same sender within 24h all between $2800-$2999',
     'NOT EXISTS (SELECT 1 FROM CURATED_DEV.WU_PAYMENTS.FACT_TRANSACTIONS t2 WHERE t2.SENDER_ID = FACT_TRANSACTIONS.SENDER_ID AND t2.AMOUNT_USD BETWEEN 2800 AND 2999 AND t2.CREATED_AT BETWEEN DATEADD(''hour'', -24, FACT_TRANSACTIONS.CREATED_AT) AND FACT_TRANSACTIONS.CREATED_AT HAVING COUNT(*) >= 3)',
     'ROW', 100.0, NULL, 'HIGH', 'ALERT', TRUE)
    AS t(RULE_ID, CONTRACT_ID, SOURCE_SYSTEM, RULE_NAME, RULE_DESCRIPTION,
         RULE_EXPRESSION, RULE_TYPE, THRESHOLD_PERCENT, WARNING_THRESHOLD,
         SEVERITY, ON_FAILURE, IS_ACTIVE)
) src ON tgt.RULE_ID = src.RULE_ID
WHEN MATCHED THEN UPDATE SET
    RULE_NAME = src.RULE_NAME,
    RULE_EXPRESSION = src.RULE_EXPRESSION,
    SEVERITY = src.SEVERITY,
    ON_FAILURE = src.ON_FAILURE
WHEN NOT MATCHED THEN INSERT (
    RULE_ID, CONTRACT_ID, SOURCE_SYSTEM, RULE_NAME, RULE_DESCRIPTION,
    RULE_EXPRESSION, RULE_TYPE, THRESHOLD_PERCENT, WARNING_THRESHOLD,
    SEVERITY, ON_FAILURE, IS_ACTIVE
) VALUES (
    src.RULE_ID, src.CONTRACT_ID, src.SOURCE_SYSTEM, src.RULE_NAME, src.RULE_DESCRIPTION,
    src.RULE_EXPRESSION, src.RULE_TYPE, src.THRESHOLD_PERCENT, src.WARNING_THRESHOLD,
    src.SEVERITY, src.ON_FAILURE, src.IS_ACTIVE
);

-- SLA for FACT_TRANSACTIONS
MERGE INTO SLA_DEFINITIONS tgt USING (
    SELECT
        'WU-SLA-TXN-001' AS SLA_ID,
        'CONTRACT-WU_PAYMENTS-FACT_TRANSACTIONS-001' AS CONTRACT_ID,
        'WU_PAYMENTS' AS SOURCE_SYSTEM,
        0.08 AS FRESHNESS_TARGET_HOURS,  -- 5 minutes
        0.25 AS FRESHNESS_MAX_HOURS,     -- 15 minutes
        99.9 AS AVAILABILITY_TARGET_PCT,
        NULL AS MIN_ROW_COUNT,
        NULL AS MAX_ROW_COUNT,
        'ALERT' AS ON_SLA_MISS,
        TRUE AS IS_ACTIVE
) src ON tgt.SLA_ID = src.SLA_ID
WHEN MATCHED THEN UPDATE SET
    FRESHNESS_TARGET_HOURS = src.FRESHNESS_TARGET_HOURS,
    AVAILABILITY_TARGET_PCT = src.AVAILABILITY_TARGET_PCT
WHEN NOT MATCHED THEN INSERT (
    SLA_ID, CONTRACT_ID, SOURCE_SYSTEM,
    FRESHNESS_TARGET_HOURS, FRESHNESS_MAX_HOURS,
    AVAILABILITY_TARGET_PCT, MIN_ROW_COUNT, MAX_ROW_COUNT,
    ON_SLA_MISS, IS_ACTIVE
) VALUES (
    src.SLA_ID, src.CONTRACT_ID, src.SOURCE_SYSTEM,
    src.FRESHNESS_TARGET_HOURS, src.FRESHNESS_MAX_HOURS,
    src.AVAILABILITY_TARGET_PCT, src.MIN_ROW_COUNT, src.MAX_ROW_COUNT,
    src.ON_SLA_MISS, src.IS_ACTIVE
);

-- ═══════════════════════════════════════════════════════════════════════════
-- CONTRACT 2: WU_KYC.DIM_CUSTOMER
-- ═══════════════════════════════════════════════════════════════════════════

MERGE INTO CONTRACT_REGISTRY tgt
USING (
    SELECT
        'CONTRACT-WU_KYC-DIM_CUSTOMER-001' AS CONTRACT_ID,
        'WU KYC DIM_CUSTOMER Data Contract' AS CONTRACT_NAME,
        '1.0' AS CONTRACT_VERSION,
        'ACTIVE' AS CONTRACT_STATUS,
        'WU_KYC' AS SOURCE_SYSTEM,
        'DIM_CUSTOMER' AS SOURCE_TABLE,
        'CURATED_DEV.WU_KYC.DIM_CUSTOMER' AS FULL_TABLE_PATH,
        'WU KYC Operations' AS PRODUCER_TEAM,
        'kyc-ops@westernunion.com' AS PRODUCER_OWNER_EMAIL,
        PARSE_JSON('["WU Compliance","WU Analytics","CDO Office"]') AS CONSUMER_TEAMS,
        PARSE_JSON('{
            "required_columns": ["CUSTOMER_ID","KYC_STATUS","COUNTRY"],
            "not_null": ["CUSTOMER_ID","KYC_STATUS"],
            "check_constraints": {"COUNTRY": "RLIKE ''^[A-Z]{2}$''"}
        }') AS SCHEMA_DEFINITION,
        PARSE_JSON('{
            "rules": ["WU_CUST_KYC_NOT_STALE","WU_CUST_PHONE_FORMAT","WU_CUST_NO_EXPIRED_VERIFIED"]
        }') AS QUALITY_DEFINITION,
        PARSE_JSON('{
            "freshness_hours": 4,
            "availability_pct": 99.9
        }') AS SLA_DEFINITION,
        PARSE_JSON('{
            "classification": "RESTRICTED",
            "retention_days": 3650,
            "pii_columns": ["FULL_NAME","COUNTRY","STATE","CITY"]
        }') AS GOVERNANCE_DEFINITION,
        'Customer identity and KYC master data — compliance-critical' AS DESCRIPTION
) src ON tgt.CONTRACT_ID = src.CONTRACT_ID
WHEN MATCHED THEN UPDATE SET
    CONTRACT_NAME = src.CONTRACT_NAME,
    UPDATED_AT = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
    CONTRACT_ID, CONTRACT_NAME, CONTRACT_VERSION, CONTRACT_STATUS,
    SOURCE_SYSTEM, SOURCE_TABLE, FULL_TABLE_PATH,
    PRODUCER_TEAM, PRODUCER_OWNER_EMAIL, CONSUMER_TEAMS,
    SCHEMA_DEFINITION, QUALITY_DEFINITION, SLA_DEFINITION, GOVERNANCE_DEFINITION,
    DESCRIPTION
) VALUES (
    src.CONTRACT_ID, src.CONTRACT_NAME, src.CONTRACT_VERSION, src.CONTRACT_STATUS,
    src.SOURCE_SYSTEM, src.SOURCE_TABLE, src.FULL_TABLE_PATH,
    src.PRODUCER_TEAM, src.PRODUCER_OWNER_EMAIL, src.CONSUMER_TEAMS,
    src.SCHEMA_DEFINITION, src.QUALITY_DEFINITION, src.SLA_DEFINITION, src.GOVERNANCE_DEFINITION,
    src.DESCRIPTION
);

-- Quality rules for DIM_CUSTOMER
MERGE INTO QUALITY_RULES tgt USING (
    SELECT * FROM VALUES
    ('WU-QR-CUST-001', 'CONTRACT-WU_KYC-DIM_CUSTOMER-001', 'WU_KYC',
     'WU_CUST_KYC_NOT_STALE', 'KYC expiry date must not be in the past',
     'KYC_EXPIRY_DATE >= CURRENT_DATE()', 'ROW', 100.0, 95.0, 'ERROR', 'BLOCK', TRUE),
    ('WU-QR-CUST-002', 'CONTRACT-WU_KYC-DIM_CUSTOMER-001', 'WU_KYC',
     'WU_CUST_PHONE_FORMAT', 'Phone number must match E.164 format',
     'PHONE IS NULL OR PHONE RLIKE ''^\\+[1-9]\\d{1,14}$''', 'ROW', 100.0, 90.0, 'WARNING', 'ALERT', TRUE),
    ('WU-QR-CUST-003', 'CONTRACT-WU_KYC-DIM_CUSTOMER-001', 'WU_KYC',
     'WU_CUST_NO_EXPIRED_VERIFIED', 'Verified customers must not have expired KYC',
     'NOT (KYC_STATUS = ''VERIFIED'' AND KYC_EXPIRY_DATE < CURRENT_DATE())', 'ROW', 100.0, NULL, 'ERROR', 'BLOCK', TRUE)
    AS t(RULE_ID, CONTRACT_ID, SOURCE_SYSTEM, RULE_NAME, RULE_DESCRIPTION,
         RULE_EXPRESSION, RULE_TYPE, THRESHOLD_PERCENT, WARNING_THRESHOLD,
         SEVERITY, ON_FAILURE, IS_ACTIVE)
) src ON tgt.RULE_ID = src.RULE_ID
WHEN MATCHED THEN UPDATE SET
    RULE_NAME = src.RULE_NAME,
    RULE_EXPRESSION = src.RULE_EXPRESSION,
    SEVERITY = src.SEVERITY,
    ON_FAILURE = src.ON_FAILURE
WHEN NOT MATCHED THEN INSERT (
    RULE_ID, CONTRACT_ID, SOURCE_SYSTEM, RULE_NAME, RULE_DESCRIPTION,
    RULE_EXPRESSION, RULE_TYPE, THRESHOLD_PERCENT, WARNING_THRESHOLD,
    SEVERITY, ON_FAILURE, IS_ACTIVE
) VALUES (
    src.RULE_ID, src.CONTRACT_ID, src.SOURCE_SYSTEM, src.RULE_NAME, src.RULE_DESCRIPTION,
    src.RULE_EXPRESSION, src.RULE_TYPE, src.THRESHOLD_PERCENT, src.WARNING_THRESHOLD,
    src.SEVERITY, src.ON_FAILURE, src.IS_ACTIVE
);

-- SLA for DIM_CUSTOMER
MERGE INTO SLA_DEFINITIONS tgt USING (
    SELECT
        'WU-SLA-CUST-001' AS SLA_ID,
        'CONTRACT-WU_KYC-DIM_CUSTOMER-001' AS CONTRACT_ID,
        'WU_KYC' AS SOURCE_SYSTEM,
        4.0 AS FRESHNESS_TARGET_HOURS,
        8.0 AS FRESHNESS_MAX_HOURS,
        99.9 AS AVAILABILITY_TARGET_PCT,
        NULL AS MIN_ROW_COUNT,
        NULL AS MAX_ROW_COUNT,
        'ALERT' AS ON_SLA_MISS,
        TRUE AS IS_ACTIVE
) src ON tgt.SLA_ID = src.SLA_ID
WHEN MATCHED THEN UPDATE SET
    FRESHNESS_TARGET_HOURS = src.FRESHNESS_TARGET_HOURS
WHEN NOT MATCHED THEN INSERT (
    SLA_ID, CONTRACT_ID, SOURCE_SYSTEM,
    FRESHNESS_TARGET_HOURS, FRESHNESS_MAX_HOURS,
    AVAILABILITY_TARGET_PCT, MIN_ROW_COUNT, MAX_ROW_COUNT,
    ON_SLA_MISS, IS_ACTIVE
) VALUES (
    src.SLA_ID, src.CONTRACT_ID, src.SOURCE_SYSTEM,
    src.FRESHNESS_TARGET_HOURS, src.FRESHNESS_MAX_HOURS,
    src.AVAILABILITY_TARGET_PCT, src.MIN_ROW_COUNT, src.MAX_ROW_COUNT,
    src.ON_SLA_MISS, src.IS_ACTIVE
);

-- ═══════════════════════════════════════════════════════════════════════════
-- CONTRACT 3: WU_KYC.DIM_BENEFICIARY
-- ═══════════════════════════════════════════════════════════════════════════

MERGE INTO CONTRACT_REGISTRY tgt
USING (
    SELECT
        'CONTRACT-WU_KYC-DIM_BENEFICIARY-001' AS CONTRACT_ID,
        'WU KYC DIM_BENEFICIARY Data Contract' AS CONTRACT_NAME,
        '1.0' AS CONTRACT_VERSION,
        'ACTIVE' AS CONTRACT_STATUS,
        'WU_KYC' AS SOURCE_SYSTEM,
        'DIM_BENEFICIARY' AS SOURCE_TABLE,
        'CURATED_DEV.WU_KYC.DIM_BENEFICIARY' AS FULL_TABLE_PATH,
        'WU KYC Operations' AS PRODUCER_TEAM,
        'kyc-ops@westernunion.com' AS PRODUCER_OWNER_EMAIL,
        PARSE_JSON('["WU Compliance","WU Analytics"]') AS CONSUMER_TEAMS,
        PARSE_JSON('{
            "required_columns": ["BENEFICIARY_ID","CUSTOMER_ID","FULL_NAME","COUNTRY"],
            "not_null": ["BENEFICIARY_ID","FULL_NAME"],
            "check_constraints": {"COUNTRY": "RLIKE ''^[A-Z]{2}$''"}
        }') AS SCHEMA_DEFINITION,
        PARSE_JSON('{
            "rules": ["WU_BEN_NAME_NOT_NULL","WU_BEN_COUNTRY_ISO","WU_BEN_NO_DUPLICATES"]
        }') AS QUALITY_DEFINITION,
        PARSE_JSON('{
            "freshness_hours": 4,
            "availability_pct": 99.9
        }') AS SLA_DEFINITION,
        PARSE_JSON('{
            "classification": "RESTRICTED",
            "retention_days": 3650,
            "pii_columns": ["FULL_NAME","COUNTRY","CITY","BANK_NAME"]
        }') AS GOVERNANCE_DEFINITION,
        'Beneficiary (receiver) master data — sanctions screening applies' AS DESCRIPTION
) src ON tgt.CONTRACT_ID = src.CONTRACT_ID
WHEN MATCHED THEN UPDATE SET
    CONTRACT_NAME = src.CONTRACT_NAME,
    UPDATED_AT = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
    CONTRACT_ID, CONTRACT_NAME, CONTRACT_VERSION, CONTRACT_STATUS,
    SOURCE_SYSTEM, SOURCE_TABLE, FULL_TABLE_PATH,
    PRODUCER_TEAM, PRODUCER_OWNER_EMAIL, CONSUMER_TEAMS,
    SCHEMA_DEFINITION, QUALITY_DEFINITION, SLA_DEFINITION, GOVERNANCE_DEFINITION,
    DESCRIPTION
) VALUES (
    src.CONTRACT_ID, src.CONTRACT_NAME, src.CONTRACT_VERSION, src.CONTRACT_STATUS,
    src.SOURCE_SYSTEM, src.SOURCE_TABLE, src.FULL_TABLE_PATH,
    src.PRODUCER_TEAM, src.PRODUCER_OWNER_EMAIL, src.CONSUMER_TEAMS,
    src.SCHEMA_DEFINITION, src.QUALITY_DEFINITION, src.SLA_DEFINITION, src.GOVERNANCE_DEFINITION,
    src.DESCRIPTION
);

-- Quality rules for DIM_BENEFICIARY
MERGE INTO QUALITY_RULES tgt USING (
    SELECT * FROM VALUES
    ('WU-QR-BEN-001', 'CONTRACT-WU_KYC-DIM_BENEFICIARY-001', 'WU_KYC',
     'WU_BEN_NAME_NOT_NULL', 'Beneficiary full name must not be null',
     'FULL_NAME IS NOT NULL', 'ROW', 100.0, NULL, 'ERROR', 'BLOCK', TRUE),
    ('WU-QR-BEN-002', 'CONTRACT-WU_KYC-DIM_BENEFICIARY-001', 'WU_KYC',
     'WU_BEN_COUNTRY_ISO', 'Beneficiary country must be 2-char ISO code',
     'COUNTRY RLIKE ''^[A-Z]{2}$''', 'ROW', 100.0, NULL, 'ERROR', 'BLOCK', TRUE),
    ('WU-QR-BEN-003', 'CONTRACT-WU_KYC-DIM_BENEFICIARY-001', 'WU_KYC',
     'WU_BEN_NO_DUPLICATES', 'No duplicate (customer_id, full_name, country) combinations',
     'NOT EXISTS (SELECT 1 FROM CURATED_DEV.WU_KYC.DIM_BENEFICIARY b2 WHERE b2.CUSTOMER_ID = DIM_BENEFICIARY.CUSTOMER_ID AND b2.FULL_NAME = DIM_BENEFICIARY.FULL_NAME AND b2.COUNTRY = DIM_BENEFICIARY.COUNTRY AND b2.BENEFICIARY_ID != DIM_BENEFICIARY.BENEFICIARY_ID)',
     'ROW', 100.0, 95.0, 'WARNING', 'ALERT', TRUE)
    AS t(RULE_ID, CONTRACT_ID, SOURCE_SYSTEM, RULE_NAME, RULE_DESCRIPTION,
         RULE_EXPRESSION, RULE_TYPE, THRESHOLD_PERCENT, WARNING_THRESHOLD,
         SEVERITY, ON_FAILURE, IS_ACTIVE)
) src ON tgt.RULE_ID = src.RULE_ID
WHEN MATCHED THEN UPDATE SET
    RULE_NAME = src.RULE_NAME,
    RULE_EXPRESSION = src.RULE_EXPRESSION,
    SEVERITY = src.SEVERITY,
    ON_FAILURE = src.ON_FAILURE
WHEN NOT MATCHED THEN INSERT (
    RULE_ID, CONTRACT_ID, SOURCE_SYSTEM, RULE_NAME, RULE_DESCRIPTION,
    RULE_EXPRESSION, RULE_TYPE, THRESHOLD_PERCENT, WARNING_THRESHOLD,
    SEVERITY, ON_FAILURE, IS_ACTIVE
) VALUES (
    src.RULE_ID, src.CONTRACT_ID, src.SOURCE_SYSTEM, src.RULE_NAME, src.RULE_DESCRIPTION,
    src.RULE_EXPRESSION, src.RULE_TYPE, src.THRESHOLD_PERCENT, src.WARNING_THRESHOLD,
    src.SEVERITY, src.ON_FAILURE, src.IS_ACTIVE
);

-- SLA for DIM_BENEFICIARY
MERGE INTO SLA_DEFINITIONS tgt USING (
    SELECT
        'WU-SLA-BEN-001' AS SLA_ID,
        'CONTRACT-WU_KYC-DIM_BENEFICIARY-001' AS CONTRACT_ID,
        'WU_KYC' AS SOURCE_SYSTEM,
        4.0 AS FRESHNESS_TARGET_HOURS,
        8.0 AS FRESHNESS_MAX_HOURS,
        99.9 AS AVAILABILITY_TARGET_PCT,
        NULL AS MIN_ROW_COUNT,
        NULL AS MAX_ROW_COUNT,
        'ALERT' AS ON_SLA_MISS,
        TRUE AS IS_ACTIVE
) src ON tgt.SLA_ID = src.SLA_ID
WHEN MATCHED THEN UPDATE SET
    FRESHNESS_TARGET_HOURS = src.FRESHNESS_TARGET_HOURS
WHEN NOT MATCHED THEN INSERT (
    SLA_ID, CONTRACT_ID, SOURCE_SYSTEM,
    FRESHNESS_TARGET_HOURS, FRESHNESS_MAX_HOURS,
    AVAILABILITY_TARGET_PCT, MIN_ROW_COUNT, MAX_ROW_COUNT,
    ON_SLA_MISS, IS_ACTIVE
) VALUES (
    src.SLA_ID, src.CONTRACT_ID, src.SOURCE_SYSTEM,
    src.FRESHNESS_TARGET_HOURS, src.FRESHNESS_MAX_HOURS,
    src.AVAILABILITY_TARGET_PCT, src.MIN_ROW_COUNT, src.MAX_ROW_COUNT,
    src.ON_SLA_MISS, src.IS_ACTIVE
);

-- ═══════════════════════════════════════════════════════════════════════════
-- CONTRACT VALIDATION PROCEDURE
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE PROCEDURE GOVERNANCE.CONTRACTS.SP_WU_VALIDATE_ALL_CONTRACTS()
RETURNS VARIANT
LANGUAGE JAVASCRIPT
EXECUTE AS CALLER
AS
$$
    var results = [];

    // Fetch all active WU quality rules
    var rulesSql = `
        SELECT r.RULE_ID, r.CONTRACT_ID, r.RULE_NAME, r.RULE_EXPRESSION,
               r.SEVERITY, r.ON_FAILURE, r.THRESHOLD_PERCENT,
               c.FULL_TABLE_PATH, c.SOURCE_TABLE
        FROM GOVERNANCE.CONTRACTS.QUALITY_RULES r
        JOIN GOVERNANCE.CONTRACTS.CONTRACT_REGISTRY c
            ON r.CONTRACT_ID = c.CONTRACT_ID
        WHERE r.IS_ACTIVE = TRUE
          AND c.CONTRACT_STATUS = 'ACTIVE'
          AND r.SOURCE_SYSTEM LIKE 'WU_%'
        ORDER BY r.CONTRACT_ID, r.RULE_ID
    `;

    var rulesStmt = snowflake.createStatement({sqlText: rulesSql});
    var rulesResult = rulesStmt.execute();

    var currentContract = null;
    var contractResult = null;

    while (rulesResult.next()) {
        var ruleId = rulesResult.getColumnValue(1);
        var contractId = rulesResult.getColumnValue(2);
        var ruleName = rulesResult.getColumnValue(3);
        var ruleExpr = rulesResult.getColumnValue(4);
        var severity = rulesResult.getColumnValue(5);
        var onFailure = rulesResult.getColumnValue(6);
        var threshold = rulesResult.getColumnValue(7);
        var tablePath = rulesResult.getColumnValue(8);
        var sourceTable = rulesResult.getColumnValue(9);

        // Start new contract group
        if (contractId !== currentContract) {
            if (contractResult) results.push(contractResult);
            currentContract = contractId;
            contractResult = {
                contract_id: contractId,
                table: tablePath,
                passed: true,
                rules_checked: 0,
                rules_passed: 0,
                rules_failed: 0,
                violations: []
            };
        }

        try {
            // Check compliance rate for this rule
            var checkSql = "SELECT COUNT(*) AS total, " +
                "COUNT(CASE WHEN " + ruleExpr + " THEN 1 END) AS passing " +
                "FROM " + tablePath;

            var checkStmt = snowflake.createStatement({sqlText: checkSql});
            var checkResult = checkStmt.execute();
            checkResult.next();

            var total = checkResult.getColumnValue(1);
            var passing = checkResult.getColumnValue(2);
            var pct = total > 0 ? (passing / total) * 100 : 100;
            var passed = pct >= threshold;

            contractResult.rules_checked++;
            if (passed) {
                contractResult.rules_passed++;
            } else {
                contractResult.rules_failed++;
                contractResult.passed = false;
                contractResult.violations.push({
                    rule_id: ruleId,
                    rule_name: ruleName,
                    severity: severity,
                    on_failure: onFailure,
                    compliance_pct: Math.round(pct * 100) / 100,
                    threshold_pct: threshold,
                    failing_rows: total - passing
                });

                // Quarantine failing records for BLOCK rules
                if (onFailure === 'BLOCK' && total - passing > 0) {
                    try {
                        var quarantineSql = "INSERT INTO GOVERNANCE.CONTRACTS.WU_QUARANTINE " +
                            "(SOURCE_TABLE, RECORD_ID, RULE_ID, RULE_NAME, VIOLATION_DETAILS) " +
                            "SELECT '" + tablePath + "', " +
                            sourceTable + "." + (sourceTable === 'FACT_TRANSACTIONS' ? 'TRANSACTION_ID' :
                                                  sourceTable === 'DIM_CUSTOMER' ? 'CUSTOMER_ID' :
                                                  'BENEFICIARY_ID') + ", " +
                            "'" + ruleId + "', '" + ruleName + "', " +
                            "OBJECT_CONSTRUCT('severity', '" + severity + "', 'expression', '" +
                            ruleExpr.replace(/'/g, "''") + "') " +
                            "FROM " + tablePath + " " + sourceTable + " " +
                            "WHERE NOT (" + ruleExpr + ") LIMIT 1000";
                        snowflake.createStatement({sqlText: quarantineSql}).execute();
                    } catch (qErr) {
                        // Quarantine is best-effort
                    }
                }
            }
        } catch (ruleErr) {
            contractResult.rules_checked++;
            contractResult.rules_failed++;
            contractResult.passed = false;
            contractResult.violations.push({
                rule_id: ruleId,
                rule_name: ruleName,
                severity: severity,
                error: ruleErr.message
            });
        }
    }

    // Push last contract
    if (contractResult) results.push(contractResult);

    // Log to validation history
    for (var i = 0; i < results.length; i++) {
        var r = results[i];
        try {
            var histSql = "INSERT INTO GOVERNANCE.CONTRACTS.VALIDATION_HISTORY " +
                "(CONTRACT_ID, SOURCE_SYSTEM, VALIDATION_END, QUALITY_PASSED, OVERALL_PASSED, VALIDATION_DETAILS) " +
                "VALUES ('" + r.contract_id + "', 'WU', CURRENT_TIMESTAMP(), " +
                r.passed + ", " + r.passed + ", PARSE_JSON('" +
                JSON.stringify(r).replace(/'/g, "''") + "'))";
            snowflake.createStatement({sqlText: histSql}).execute();
        } catch (histErr) {
            // History logging is best-effort
        }
    }

    // Summary
    var totalPassed = 0, totalFailed = 0;
    for (var j = 0; j < results.length; j++) {
        if (results[j].passed) totalPassed++;
        else totalFailed++;
    }

    return {
        status: totalFailed === 0 ? 'ALL_CONTRACTS_PASSED' : 'CONTRACTS_FAILED',
        contracts_checked: results.length,
        contracts_passed: totalPassed,
        contracts_failed: totalFailed,
        details: results
    };
$$;

GRANT USAGE ON PROCEDURE GOVERNANCE.CONTRACTS.SP_WU_VALIDATE_ALL_CONTRACTS() TO ROLE DATA_ENGINEER;
GRANT USAGE ON PROCEDURE GOVERNANCE.CONTRACTS.SP_WU_VALIDATE_ALL_CONTRACTS() TO ROLE DATA_STEWARD;

-- ═══════════════════════════════════════════════════════════════════════════
-- VERIFICATION
-- ═══════════════════════════════════════════════════════════════════════════

SELECT CONTRACT_ID, CONTRACT_NAME, CONTRACT_STATUS
FROM GOVERNANCE.CONTRACTS.CONTRACT_REGISTRY
WHERE SOURCE_SYSTEM LIKE 'WU_%'
ORDER BY CONTRACT_ID;

SELECT RULE_ID, RULE_NAME, SEVERITY, ON_FAILURE
FROM GOVERNANCE.CONTRACTS.QUALITY_RULES
WHERE SOURCE_SYSTEM LIKE 'WU_%'
ORDER BY RULE_ID;

SELECT '05_wu_contracts.sql completed successfully' AS STATUS;
