# Ashley Session -- 60-Minute Hands-On Demo Script

> **For Surekha Durvasula, CDO at Western Union.**
> No slides. Live only. Every artifact runs against WU synthetic data.

**Format**: 20 min semantic + quality | 40 min pipeline automation
**Environment**: WU demo environment with all 8 SQL scripts deployed, Trust Dashboard running

---

## Pre-Session Checklist

- [ ] All 8 SQL scripts executed successfully
- [ ] `generate_wu_data.py` has been run, data loaded
- [ ] Trust Dashboard (Streamlit) running and accessible
- [ ] Cortex Analyst connected to SEM_DEV.WU_REMITTANCE semantic views
- [ ] Cortex Code open and connected to the WU environment
- [ ] Inject 2-3 bad records into RAW for the quality demo (but don't remediate yet)
- [ ] Verify role-switching works (DATA_ANALYST, COMPLIANCE_OFFICER, EXECUTIVE)

---

## Part 1: Semantic Contracts + Quality (20 min)

### Minute 0-5: The Semantic Layer

Open the Trust Dashboard. Start as DATA_ANALYST.

**Show**: Corridor Analytics tab. 10 corridors, transaction counts, volumes, compliance hold percentages.

> "This is one semantic view -- TRANSACTION_VOLUME_BY_CORRIDOR. It joins across your payments and compliance schemas. Every consumer gets the same definition of 'transaction volume.'"

**Ask Cortex Analyst**: "Show me transaction volume by corridor for the last 30 days."

> "Same answer, different interface. The semantic view is the single source of truth whether a human asks in English or a dashboard queries the view."

### Minute 5-10: Role-Switching (The Governance Moment)

Switch to COMPLIANCE_OFFICER in the sidebar.

> "Same view. Same query. Different answer."

Point out: PII is now visible. Customer Risk tab shows drill-through to individual transactions.

Switch to EXECUTIVE.

> "Board-level view. Top 5 corridors, total volume, compliance hold percentage. No detail, no drill-through."

Switch back to DATA_ANALYST.

> "Three personas, one dashboard, zero application logic. The governance policies do the work. Add a new role next month -- update the policy, not the app."

### Minute 10-15: Data Quality Dashboard

Click to the Data Quality tab.

**Show the KPI row**: Freshness 97.2%, Completeness 94.8%, Accuracy 99.1%, 23 quarantined records.

**Show the contract validation table**: 10 rules across 3 contracts. Most pass. Highlight the failures:
- "No structuring" rule: 12 violations (transactions just under $3,000 threshold)
- "Phone must be E.164": 15 violations
- "Country must be ISO-3166": 6 violations

> "These contracts are YOUR business rules, codified. The platform enforces them continuously. The quarantine queue shows what failed and why."

### Minute 15-20: AI Remediation

> "Let's fix the country codes right now."

Run the remediation SP (or show the Remediation History section if pre-run):

> "Cortex AI standardized 'UK' to 'GB', 'Philipines' to 'PH'. The accuracy score recovered. No ticket, no engineer paged, no manual lookup table."

**Pause. Let this land.**

> "This is the answer to your Question B. The reference schema definitions are available to Snowflake. The contracts define 'correct.' The DMFs detect drift. Cortex AI remediates. The quarantine prevents bad data from reaching consumers. All native, no egress."

---

## Part 2: Pipeline Automation (40 min)

### Minute 20-30: AI Builds the Entire Stack from Source Data

Open Cortex Code. Show the raw CSV files in the data directory.

> "Surekha, your Question A was about automating pipelines end to end. Let me start from the beginning. These are CSV files — raw exports from your payment processing, KYC, and compliance systems. No schemas defined. No pipeline code written. Just flat files."

**Step 1: AI creates the RAW layer**

Type the prompt:

> "I have CSV source files for a cross-border payment platform: transactions, customers, beneficiaries, corridors, agents, watchlist entities, SARs, and devices. Create the RAW layer — infer schemas from these files, create tables, and load the data with appropriate metadata columns (_LOADED_AT, _SOURCE_SYSTEM)."

Watch Cortex Code generate:
1. Schema creation DDL (RAW_DEV.WU_PAYMENTS, WU_KYC, WU_COMPLIANCE)
2. File format definitions
3. INFER_SCHEMA calls for each CSV
4. CREATE TABLE statements with inferred columns
5. COPY INTO statements with metadata enrichment

> "No data engineer wrote this. The AI examined the source files, inferred the types, separated concerns into three schemas, and produced production-grade DDL. This is your raw layer — source-aligned, append-only, timestamped."

**Step 2: AI creates the CURATED layer**

Type the next prompt:

> "Now build the curated layer. Create Dynamic Tables that transform these raw tables into clean dimensions and facts. Use proper naming (DIM_CUSTOMER, FACT_TRANSACTIONS). Apply appropriate TARGET_LAG — 1 minute for transactions, 1 hour for dimensions. Filter for current records."

Watch Cortex Code generate:
1. Dynamic Table DDL for DIM_CUSTOMER, DIM_BENEFICIARY, DIM_AGENT, DIM_CORRIDOR
2. Dynamic Table DDL for FACT_TRANSACTIONS, FACT_SARS
3. TARGET_LAG settings per table type
4. Business-friendly column renaming
5. Type casting and null handling

> "The curated layer writes itself. Dynamic Tables handle the refresh — no Airflow, no scheduler, no manual ETL. You set the freshness target, Snowflake handles the rest."

**Step 3: AI creates the SEMANTIC layer**

Type the final prompt:

> "Build semantic views on top of the curated layer for Cortex Analyst. Create views for: transaction volume by corridor, customer risk profiles, agent compliance scorecards, and corridor risk heatmaps. Include joins across schemas. Make them queryable in natural language."

Watch Cortex Code generate:
1. Four semantic views with business-friendly naming
2. Cross-schema joins (payments + KYC + compliance)
3. Computed metrics (risk scores, hold rates, SAR rates)
4. View comments explaining what each answers

> "Three prompts. Three layers. Zero hand-coded pipelines. The AI understood the domain — it knows 'corridor' means a country-to-country pair, it knows 'compliance hold rate' is a ratio. It built the same medallion architecture your team would build manually, but in three minutes instead of three sprints."

**Pause. Let this land.**

> "THIS is the answer to your Question A. The data is visible to Snowflake. Cortex Code has the schema context. You describe what you want in English. It generates production-grade SQL following YOUR conventions — not a prototype, not pseudocode, real deployable artifacts."

---

### Minute 30-35: Extend the Stack from a New Requirement

> "Now let's do what would normally be a new JIRA ticket and a two-week sprint."

Type the prompt:

> "Build a corridor risk monitoring pipeline that flags corridors with > 5% compliance hold rate in the last 7 days."

Watch Cortex Code generate:
1. A Dynamic Table (DT_CORRIDOR_RISK_7D)
2. A data contract with 3 validation rules
3. A DMF for freshness monitoring
4. A semantic view exposing the metric

> "A new analytical pipeline — from requirement to deployable artifact in 60 seconds. The contract rules are WU-specific. The DMF monitors freshness automatically. This isn't a template — it's generated from your schema context."

### Minute 35-45: Review and Deploy

Review the generated artifacts with the audience:

- **Dynamic Table**: "The TARGET_LAG is 1 hour. For corridor risk monitoring, that's appropriate -- you don't need sub-minute here."
- **Contract**: "Three rules: hold percentage between 0-100, risk status is a valid enum, transaction count is positive. These are sanity checks, not business rules yet -- your team would add the real thresholds."
- **Semantic View**: "This exposes CORRIDOR_RISK_MONITOR to Cortex Analyst. Anyone with the right role can ask 'which corridors are flagged' in English."

Deploy to the dev environment:

```sql
-- Execute the generated artifacts
-- (Cortex Code can do this directly, or copy-paste into a worksheet)
```

### Minute 45-50: Validate and Test

Run contract validation:

```sql
CALL GOVERNANCE.CONTRACTS.SP_WU_VALIDATE_ALL_CONTRACTS();
```

All contracts pass -- including the new one.

**Ask Cortex Analyst** the new question:

> "Which corridors are flagged for high compliance hold rates this week?"

> "Forty minutes ago, this question couldn't be answered. Now it's a semantic view, governed by contracts, monitored by DMFs, accessible in English."

### Minute 50-55: The SDLC Gate

Show what happens when a contract fails:

> "Let's tighten the threshold. What if WU policy says any corridor over 3% hold rate should block promotion?"

Modify the contract threshold. Run validation again. It fails.

> "The promotion is blocked. Not by a human reviewer. Not by a JIRA ticket. By a contract gate that YOUR team defined. The engineer can't push this to production until the business decides: adjust the threshold or investigate the corridors."

### Minute 55-60: Close

> "Let me summarize what just happened."

> "We started with CSV files. Flat files from three source systems. No schemas, no pipelines, no governance. In three prompts, AI built the entire medallion architecture — RAW, CURATED, SEMANTIC — regardless of source system format."

> "We queried the result in English. Three different roles got three different answers from the same query. Zero application logic — governance policies do the work."

> "We monitored quality with DMFs. When data drifted, Cortex AI fixed it automatically. No ticket, no engineer paged, no manual lookup table."

> "Then we extended the platform with a new requirement — from English sentence to deployed pipeline in 60 seconds. Contract gates prevent bad code from reaching production."

> "This is not a product demo. Your team just watched AI build a governed data platform from source files, enforce quality automatically, and extend the platform from natural language. The question isn't whether Snowflake can do this. The question is which source system your team wants to onboard first."

---

## Fallback Plans

**If Snowflake connection fails**: The Streamlit app has full demo fallback data. All tabs work without a live connection. Cortex Analyst won't work -- switch to showing the semantic view definitions directly.

**If Cortex Code is slow**: Have the generated artifacts pre-prepared in a SQL worksheet. Show Cortex Code generating them, then switch to the pre-built version for deployment.

**If time runs short**: Cut the SDLC gate demo (Minute 50-55). The core message lands with the pipeline generation and contract validation.

**If Surekha asks about Monte Carlo**: "DMFs are the enforcement layer -- native, zero egress, sub-minute. Monte Carlo is the intelligence layer -- ML anomaly detection, cross-platform coverage. They're complementary. The contracts here integrate with either."
