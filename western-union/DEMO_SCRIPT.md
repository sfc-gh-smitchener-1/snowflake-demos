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

### Minute 20-30: Generate a Pipeline from a Prompt

Open Cortex Code.

> "Surekha, your Question A was about automating pipelines end to end. Let me show you what that looks like."

Type the prompt:

> "Build a corridor risk monitoring pipeline that flags corridors with > 5% compliance hold rate in the last 7 days."

Watch Cortex Code generate:
1. A Dynamic Table (DT_CORRIDOR_RISK_7D)
2. A data contract with 3 validation rules
3. A DMF for freshness monitoring
4. A semantic view exposing the metric

> "Everything you see is real SQL. It references the tables from Part 1. The contract rules are WU-specific. This isn't a template -- it's generated from your schema context."

### Minute 30-40: Review and Deploy

Review the generated artifacts with the audience:

- **Dynamic Table**: "The TARGET_LAG is 1 hour. For corridor risk monitoring, that's appropriate -- you don't need sub-minute here."
- **Contract**: "Three rules: hold percentage between 0-100, risk status is a valid enum, transaction count is positive. These are sanity checks, not business rules yet -- your team would add the real thresholds."
- **Semantic View**: "This exposes CORRIDOR_RISK_MONITOR to Cortex Analyst. Anyone with the right role can ask 'which corridors are flagged' in English."

Deploy to the dev environment:

```sql
-- Execute the generated artifacts
-- (Cortex Code can do this directly, or copy-paste into a worksheet)
```

### Minute 40-50: Validate and Test

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

> "We started with governed data -- medallion architecture, contracts, masking, row-level security. That was 8 SQL scripts and a data generator."

> "We queried it in English. Three different roles got three different answers from the same query. Zero application logic."

> "We monitored it with DMFs. When quality drifted, Cortex AI fixed it automatically. No ticket, no manual intervention."

> "Then we generated a new pipeline from a sentence. Real SQL, not a prototype. We validated it against contracts. We deployed it through SDLC gates."

> "This isn't a product demo. Your team just saw production-grade artifacts generated from a prompt, validated against contracts, and deployed through your SDLC. The question isn't whether Snowflake can do this. The question is which pipeline your team wants to build first."

---

## Fallback Plans

**If Snowflake connection fails**: The Streamlit app has full demo fallback data. All tabs work without a live connection. Cortex Analyst won't work -- switch to showing the semantic view definitions directly.

**If Cortex Code is slow**: Have the generated artifacts pre-prepared in a SQL worksheet. Show Cortex Code generating them, then switch to the pre-built version for deployment.

**If time runs short**: Cut the SDLC gate demo (Minute 50-55). The core message lands with the pipeline generation and contract validation.

**If Surekha asks about Monte Carlo**: "DMFs are the enforcement layer -- native, zero egress, sub-minute. Monte Carlo is the intelligence layer -- ML anomaly detection, cross-platform coverage. They're complementary. The contracts here integrate with either."
