# Workshop 3 -- Automated Quality + Remediation

> **Objective**: Attach continuous monitoring to the pipeline from Workshops 1-2. Demonstrate that quality failures are detected, quarantined, and remediated automatically -- not by humans opening tickets.

**Duration**: 90 minutes
**DCA Modules**: `06_wu_quality_automation.sql`, Cortex AI functions, lineage
**Prerequisites**: Workshops 1-2 completed (curated tables + semantic views active)

---

## Hands-On Steps

### Step 1: Attach DMFs (15 min)

Execute `06_wu_quality_automation.sql`. 6 Data Metric Functions attach to 3 tables:

| Table | DMF | What It Measures |
|-------|-----|-----------------|
| FACT_TRANSACTIONS | Freshness | Time since last record ingested |
| FACT_TRANSACTIONS | Completeness | NULL rate on required columns |
| DIM_CUSTOMER | Completeness | NULL rate on PHONE, EMAIL |
| DIM_CUSTOMER | Accuracy (phone) | E.164 format compliance |
| DIM_BENEFICIARY | Completeness | NULL rate on FULL_NAME, COUNTRY |
| DIM_BENEFICIARY | Accuracy (country) | ISO-3166 country code validation |

**Show participants**: DMFs run on schedule. No external tool, no egress, no agent to install.

```sql
-- Check DMF results
SELECT *
FROM TABLE(INFORMATION_SCHEMA.DATA_METRIC_FUNCTION_REFERENCES(
    REF_ENTITY_NAME => 'CURATED_DEV.WU_PAYMENTS.FACT_TRANSACTIONS',
    REF_ENTITY_DOMAIN => 'TABLE'
));
```

### Step 2: DMF Coverage Analysis (15 min)

Use Cortex Code's data-quality skill to analyze current coverage:

> "Analyze DMF coverage for the WU_PAYMENTS and WU_KYC schemas. What should we add?"

Cortex Code will:
- Inventory existing DMFs
- Identify unmonitored columns with high business importance
- Recommend additional monitors (e.g., uniqueness on TRANSACTION_ID, referential integrity between SENDER_ID and CUSTOMER_ID)

**The point**: Tooling can help you find gaps in monitoring coverage, not just react to failures.

### Step 3: Inject Bad Data (15 min)

Insert records with known quality issues:

```sql
-- Malformed country codes
INSERT INTO RAW_DEV.WU_KYC.BENEFICIARIES
SELECT OBJECT_CONSTRUCT(
    'beneficiary_id', 'BEN-BREAK-001',
    'customer_id', 'CUST-00001',
    'full_name', 'Test Beneficiary',
    'country', 'UK',  -- Should be 'GB'
    'created_at', CURRENT_TIMESTAMP()::STRING
);

-- Invalid phone format
INSERT INTO RAW_DEV.WU_KYC.CUSTOMERS
SELECT OBJECT_CONSTRUCT(
    'customer_id', 'CUST-BREAK-001',
    'full_name', 'Test Customer',
    'phone', '555-0123',  -- Should be +15550123
    'email', 'test@example.com',
    'country', 'US',
    'kyc_status', 'VERIFIED',
    'created_at', CURRENT_TIMESTAMP()::STRING
);
```

Wait for Dynamic Table refresh. Then check the quality dashboard:

```sql
CALL CURATED_DEV.WU_KYC.SP_WU_QUALITY_DASHBOARD_DATA();
-- Accuracy scores dropped. Completeness still high. Freshness normal.
```

### Step 4: AI Remediation Live (20 min)

Run the AI-powered remediation stored procedures:

```sql
-- Fix country codes using Cortex AI (mistral-large)
CALL CURATED_DEV.WU_KYC.SP_WU_REMEDIATE_COUNTRY_CODES();
-- 'UK' -> 'GB', 'Philipines' -> 'PH', etc.

-- Fix phone formats using Cortex AI (mistral-large)
CALL CURATED_DEV.WU_KYC.SP_WU_REMEDIATE_PHONE_FORMAT();
-- '555-0123' -> '+15550123', etc.
```

**Show participants**: Before and after. The accuracy DMF scores recover after remediation. The quarantine table shows what was fixed and by what method.

```sql
SELECT * FROM GOVERNANCE.CONTRACTS.WU_QUARANTINE
WHERE REMEDIATED_AT IS NOT NULL
ORDER BY REMEDIATED_AT DESC;
```

### Step 5: Trace Upstream with Lineage (10 min)

A quality failure in CUSTOMER_RISK_PROFILE (semantic view) -- trace it back:

```
CUSTOMER_RISK_PROFILE (SEM_DEV)
  <- DIM_CUSTOMER (CURATED_DEV.WU_KYC)
    <- CUSTOMERS (RAW_DEV.WU_KYC)
      <- customers.csv (WU_DATA_STAGE)
```

**Show participants**: The lineage trace reveals that the bad phone format originated in the KYC source system. The AI remediation fixed it at the curated layer. The semantic view now shows clean data. The fix propagated downstream automatically.

---

## Monte Carlo Positioning

> "DMFs are native to Snowflake -- zero egress, sub-minute latency, enforced at the platform level. They're the enforcement layer. Monte Carlo provides richer anomaly detection ML, cross-platform coverage, and incident management workflows. They're complementary."

> "If Surekha asks: 'Does this replace Monte Carlo?' The answer is no. DMFs handle the rules-based monitoring that should be table stakes. Monte Carlo handles the ML-driven anomaly detection that catches the things you didn't think to write a rule for. Together they're stronger than either alone."

---

## Talk Track Snippets

> "The AI remediation isn't magic -- it's applying Surekha's own patent concept. The reference schema definitions ARE available to Snowflake. Cortex AI uses them to harmonize data from disparate sources. The configurable functions are the contracts and remediation SPs."

> "Notice: no human opened a ticket. No data engineer was paged. The contract detected the violation, quarantined the record, and the scheduled remediation fixed it. The semantic layer never saw the bad data."

---

## Takeaway

Participants leave Workshop 3 with:

- 6 DMFs continuously monitoring WU data quality
- DMF coverage analysis identifying monitoring gaps
- 2 AI-powered remediation procedures that fix common data issues automatically
- Lineage tracing from semantic view to source
- A quality dashboard showing real-time scores with quarantine and remediation history
