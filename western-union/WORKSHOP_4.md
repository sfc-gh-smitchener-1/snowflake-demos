# Workshop 4 -- Pipeline Automation with Cortex Code

> **Objective**: Close the loop. Show that the entire pipeline from Workshops 1-3 can be generated, validated, and promoted from a natural language prompt. This answers Question A directly.

**Duration**: 90 minutes
**DCA Modules**: Cortex Code, SDLC pattern, contract gates
**Prerequisites**: Workshops 1-3 completed (full pipeline + quality monitoring active)

---

## Hands-On Steps

### Step 1: Open Cortex Code (10 min)

Open Cortex Code connected to the WU Snowflake environment. Verify access to the curated tables and semantic views from previous workshops.

Demonstrate the context: Cortex Code can see the existing schema, contracts, DMFs, and semantic views. It doesn't start from zero -- it starts from what you've already built.

### Step 2: Generate a Pipeline from Natural Language (25 min)

Describe a new pipeline requirement in English:

> "Build a corridor risk monitoring pipeline that flags corridors with > 5% compliance hold rate in the last 7 days. Include a Dynamic Table, a data contract, DMF attachment, and a semantic view."

Cortex Code generates:

**Dynamic Table**:
```sql
CREATE OR REPLACE DYNAMIC TABLE CURATED_DEV.WU_PAYMENTS.DT_CORRIDOR_RISK_7D
    TARGET_LAG = '1 hour'
    WAREHOUSE = ANALYTICS_WH
AS
SELECT
    c.CORRIDOR_ID,
    c.ORIGIN_COUNTRY,
    c.DESTINATION_COUNTRY,
    COUNT(*) AS TRANSACTION_COUNT,
    COUNT_IF(t.COMPLIANCE_HOLD = TRUE) AS HELD_COUNT,
    ROUND(HELD_COUNT * 100.0 / NULLIF(TRANSACTION_COUNT, 0), 2) AS HOLD_PCT,
    CASE WHEN HOLD_PCT > 5.0 THEN 'FLAGGED' ELSE 'NORMAL' END AS RISK_STATUS
FROM CURATED_DEV.WU_PAYMENTS.FACT_TRANSACTIONS t
JOIN CURATED_DEV.WU_PAYMENTS.DIM_CORRIDOR c ON t.CORRIDOR_ID = c.CORRIDOR_ID
WHERE t.CREATED_AT >= DATEADD(DAY, -7, CURRENT_TIMESTAMP())
GROUP BY c.CORRIDOR_ID, c.ORIGIN_COUNTRY, c.DESTINATION_COUNTRY;
```

**Data Contract**: Validation rules for the new table (hold_pct between 0-100, risk_status in ('FLAGGED','NORMAL'), transaction_count > 0).

**DMF**: Freshness monitor on the new Dynamic Table.

**Semantic View**: CORRIDOR_RISK_MONITOR exposing the flagged corridors to Cortex Analyst.

**Show participants**: Review the generated artifacts. They're real SQL -- reviewable, modifiable, version-controllable. The starting point was a sentence; the output is production-grade code.

### Step 3: SDLC Pattern -- Clone, Develop, Validate (20 min)

Walk through the promotion flow:

**Clone DEV environment**:
```sql
-- Create an isolated development workspace
CREATE DATABASE WU_DEV_CLONE CLONE CURATED_DEV;
```

**Deploy generated artifacts** into the clone:
- Execute the Dynamic Table definition
- Register the data contract
- Attach the DMF
- Create the semantic view

**Validate**:
```sql
-- Run contract validation against the new table
CALL GOVERNANCE.CONTRACTS.SP_WU_VALIDATE_ALL_CONTRACTS();
-- All contracts pass (including the new one)
```

### Step 4: End-to-End Execution (15 min)

The new pipeline runs against Workshop 1's data:

1. Dynamic Table refreshes (1 hour lag)
2. Data flows from FACT_TRANSACTIONS + DIM_CORRIDOR into DT_CORRIDOR_RISK_7D
3. DMF monitors freshness
4. Contract validates risk_status values

Query the result:
```sql
SELECT * FROM CURATED_DEV.WU_PAYMENTS.DT_CORRIDOR_RISK_7D
WHERE RISK_STATUS = 'FLAGGED'
ORDER BY HOLD_PCT DESC;
```

Ask Cortex Analyst via the new semantic view:
> "Which corridors are flagged for high compliance hold rates this week?"

### Step 5: Promote to Production (20 min)

Demonstrate the promotion gate pattern:

```
DEV (clone) -> Contract validation passes -> STG -> Contract validation passes -> PROD
```

At each stage:
- Contract gates run automatically
- DMF scores must meet threshold
- Failing any gate blocks promotion

**Show a failure**: Modify the contract to require hold_pct < 3% (stricter threshold). Run validation -- it fails because some corridors exceed 3%. The promotion is blocked until the business decides: adjust the threshold or investigate the corridors.

**The point**: Contract gates are not rubber stamps. They enforce business-defined quality standards at every stage of the SDLC.

---

## Talk Track Snippets

> "Your team just watched a production-grade pipeline get generated from a sentence, validated against business-defined contracts, and deployed through a governed SDLC. The artifacts are real SQL -- they can be versioned, reviewed, and maintained like any other code."

> "The difference isn't that AI wrote the code. The difference is that the contracts caught what the AI got wrong. The SDLC gates enforced your standards. The AI accelerated the starting point; the platform enforced the quality bar."

> "This isn't a product demo. Your engineers saw it work on your data, with your business rules, in your environment. They can replicate this on real pipelines tomorrow."

---

## Takeaway

Participants leave Workshop 4 with:

- A new pipeline generated entirely from natural language
- The pipeline validated against contracts at every SDLC stage
- Proof that contract gates block bad promotions
- A repeatable pattern: prompt -> generate -> validate -> promote
- The concrete answer to Question A: "This is how you automate data engineering pipelines end to end using code skills, projects, and prompts."
