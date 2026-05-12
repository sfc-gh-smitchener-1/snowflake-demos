# Workshop 1 -- From Chaos to Contract

> **Objective**: Stand up the full medallion pipeline with data contracts and governance tags using WU transaction data. Participants leave with a running pipeline they defined.

**Duration**: 90 minutes
**DCA Modules**: `01_wu_setup.sql` through `05_wu_contracts.sql`, `07_wu_governance.sql`
**Prerequisites**: Snowflake account with ACCOUNTADMIN access, data generated via `generate_wu_data.py`

---

## Setup (Before Session)

```bash
# Generate synthetic WU data
cd customer-demos/western-union/tools
python generate_wu_data.py --output ../data

# Verify 7 CSV files generated
ls ../data/
# corridors.csv, agents.csv, transactions.csv, customers.csv,
# beneficiaries.csv, devices.csv, watchlist_entries.csv, sars.csv
```

---

## Hands-On Steps

### Step 1: Load WU Synthetic Data (15 min)

Run `01_wu_setup.sql` -- creates 3 RAW schemas (WU_PAYMENTS, WU_KYC, WU_COMPLIANCE), demo roles, internal stages.

Run `02_wu_load_data.sql` -- uses INFER_SCHEMA to load all 7 CSVs. Point out: no DDL required, schema inferred from the files.

**Show participants**: Query RAW_DEV tables. Data is flat, untyped, unvalidated. This is the "chaos" state.

```sql
SELECT * FROM RAW_DEV.WU_PAYMENTS.TRANSACTIONS LIMIT 10;
-- Note: quoted lowercase column names, no types, no constraints
```

### Step 2: RAW to CURATED via Dynamic Tables (20 min)

Run `03_wu_curated_layer.sql`. 8 Dynamic Tables activate:

| Dynamic Table | Schema | TARGET_LAG | Purpose |
|--------------|--------|------------|---------|
| DIM_CORRIDOR | WU_PAYMENTS | 24 hours | Corridor reference (slow-changing) |
| DIM_AGENT | WU_PAYMENTS | 1 hour | Agent network (moderate change) |
| FACT_TRANSACTIONS | WU_PAYMENTS | 1 minute | Transaction stream (near real-time) |
| DIM_CUSTOMER | WU_KYC | 1 hour | Customer master |
| DIM_BENEFICIARY | WU_KYC | 1 hour | Beneficiary master |
| DIM_DEVICE | WU_KYC | 4 hours | Device fingerprints |
| DIM_WATCHLIST | WU_COMPLIANCE | 1 hour | Compliance watchlist |
| FACT_SARS | WU_COMPLIANCE | 5 minutes | Suspicious Activity Reports |

**Show participants**: The refresh cascade -- FACT_TRANSACTIONS at 1-minute lag pulls from RAW and auto-refreshes. No scheduler, no orchestrator.

```sql
-- Watch the refresh state
SELECT name, target_lag, refresh_mode, scheduling_state
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLES())
WHERE SCHEMA_NAME LIKE 'WU_%';
```

### Step 3: Define Data Contracts (20 min)

Run `05_wu_contracts.sql`. Walk through the 3 contracts:

**FACT_TRANSACTIONS contract**:
- Amount must be positive
- Corridor must not be null
- Status must be in ('COMPLETED','PENDING','FAILED','HELD','RETURNED')
- No structuring: flag transactions just under $3,000 reporting threshold

**DIM_CUSTOMER contract**:
- KYC must not be stale (< 365 days since last verification)
- Phone must be E.164 format
- No expired-but-verified customers (KYC_STATUS = 'VERIFIED' with expired date)

**DIM_BENEFICIARY contract**:
- Name must not be null
- Country must be valid ISO-3166 code
- No duplicate beneficiaries per customer

**Show participants**: Run `CALL GOVERNANCE.CONTRACTS.SP_WU_VALIDATE_ALL_CONTRACTS()` -- all contracts pass on clean data.

### Step 4: Break It (15 min)

Insert bad records to trigger contract violations:

```sql
-- NULL corridor + negative amount
INSERT INTO RAW_DEV.WU_PAYMENTS.TRANSACTIONS
SELECT OBJECT_CONSTRUCT(
    'transaction_id', 'TXN-BREAK-001',
    'amount_usd', -500,
    'corridor_id', NULL,
    'status', 'INVALID_STATUS',
    'sender_id', 'CUST-00001',
    'created_at', CURRENT_TIMESTAMP()::STRING
);
```

Wait for Dynamic Table refresh (1 minute for FACT_TRANSACTIONS). Then:

```sql
CALL GOVERNANCE.CONTRACTS.SP_WU_VALIDATE_ALL_CONTRACTS();
-- Shows: 3 violations on FACT_TRANSACTIONS contract
```

**Show participants**: The quarantine table now contains the bad record. It is blocked from reaching the semantic layer.

```sql
SELECT * FROM GOVERNANCE.CONTRACTS.WU_QUARANTINE ORDER BY QUARANTINED_AT DESC;
```

### Step 5: Tag and Mask (20 min)

Run `07_wu_governance.sql`. Key demonstrations:

**Tagging**:
```sql
-- Show PII tags applied
SELECT * FROM TABLE(INFORMATION_SCHEMA.TAG_REFERENCES(
    'CURATED_DEV.WU_KYC.DIM_CUSTOMER', 'TABLE'
));
```

**Masking by role**:
```sql
-- As COMPLIANCE_OFFICER: full PII visible
USE ROLE COMPLIANCE_OFFICER;
SELECT CUSTOMER_ID, FULL_NAME, PHONE, EMAIL FROM CURATED_DEV.WU_KYC.DIM_CUSTOMER LIMIT 5;

-- As DATA_ANALYST: PII masked
USE ROLE DATA_ANALYST;
SELECT CUSTOMER_ID, FULL_NAME, PHONE, EMAIL FROM CURATED_DEV.WU_KYC.DIM_CUSTOMER LIMIT 5;
-- FULL_NAME = '***MASKED***', PHONE = '***MASKED***', EMAIL = '***MASKED***'
```

---

## Talk Track Snippets

> "The TARGET_LAG values aren't arbitrary -- they map to your SLA requirements. Transactions at 1 minute because compliance needs near real-time. Corridors at 24 hours because they're reference data that rarely changes. You define the contract, Snowflake enforces it."

> "The quarantine didn't require a human to open a ticket. The contract fired, the record was blocked, and the semantic layer never saw the bad data. Your consumers don't know it happened -- they just see clean data."

> "Same table, same query, different role, different answer. That's not application logic -- that's platform governance. It works in Streamlit, in dbt, in Cortex Analyst, in any tool that connects to Snowflake."

---

## Takeaway

Participants leave Workshop 1 with:

- A running medallion pipeline (RAW -> CURATED) with 8 Dynamic Tables
- 3 data contracts enforcing WU-specific business rules
- Quarantine flow that blocks bad data automatically
- Governance tags (PII, Compliance, Residency) and masking policies active across roles
- The foundation for Workshops 2-4
