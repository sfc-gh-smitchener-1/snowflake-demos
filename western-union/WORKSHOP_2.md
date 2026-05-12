# Workshop 2 -- Making Data Speak Business

> **Objective**: Build Semantic Views on Workshop 1's curated tables. Demonstrate that the semantic schema IS the trust boundary -- consumers get natural language access, not raw tables.

**Duration**: 90 minutes
**DCA Modules**: `04_wu_semantic_layer.sql`, `08_wu_streamlit.sql`, Cortex Analyst
**Prerequisites**: Workshop 1 completed (curated tables + contracts active)

---

## Hands-On Steps

### Step 1: Build Semantic Views (20 min)

Execute `04_wu_semantic_layer.sql`. Four semantic views materialize in `SEM_DEV.WU_REMITTANCE`:

| Semantic View | Joins | Purpose |
|--------------|-------|---------|
| TRANSACTION_VOLUME_BY_CORRIDOR | FACT_TRANSACTIONS + DIM_CORRIDOR | Corridor-level volume, amount, compliance hold % |
| CUSTOMER_RISK_PROFILE | DIM_CUSTOMER + DIM_BENEFICIARY + FACT_TRANSACTIONS + FACT_SARS | Cross-system customer risk score |
| AGENT_COMPLIANCE_SCORECARD | DIM_AGENT + FACT_TRANSACTIONS + FACT_SARS | Agent network health + compliance metrics |
| CORRIDOR_RISK_HEATMAP | DIM_CORRIDOR + FACT_TRANSACTIONS (7d/30d) + FACT_SARS | Temporal risk trends by corridor |

**Show participants**: These views join across all 3 source schemas (PAYMENTS, KYC, COMPLIANCE). The consumer sees one unified business concept, not 8 tables.

```sql
-- The semantic view abstracts the complexity
SELECT * FROM SEM_DEV.WU_REMITTANCE.TRANSACTION_VOLUME_BY_CORRIDOR LIMIT 10;

-- Compare: the underlying query would require 3 joins across 2 schemas
```

### Step 2: Cortex Code Refinement (15 min)

Use Cortex Code to modify a semantic view:

> "Add a 7-day moving average of transaction volume to the corridor view"

Show how Cortex Code generates the window function, validates the SQL, and updates the view definition. The point: semantic models can be iterated in natural language without touching the pipeline.

### Step 3: Ask Cortex Analyst (25 min)

Connect Cortex Analyst to the WU semantic views. Demonstrate progressively complex questions:

**Simple aggregation**:
> "Show me transaction volume by corridor for the last 30 days"

**Filtered analysis**:
> "Which corridors have the highest compliance hold rate?"

**Cross-domain intelligence**:
> "Top 5 agents by SAR count with their transaction volumes"

**Trend analysis**:
> "How has the US-to-Mexico corridor volume changed month over month?"

Each question returns:
- The generated SQL (show it -- participants should see it's hitting the semantic view, not raw tables)
- The result set
- Optional visualization

### Step 4: Role-Switch in Trust Dashboard (30 min)

Open the Streamlit Trust Dashboard (`streamlit/app.py`). This is the core demo moment.

**As DATA_ANALYST**:
- Corridor Analytics tab shows full corridor breakdown
- PII columns show `***MASKED***`
- All corridors visible (no RLS filtering on analyst role)
- Can see compliance hold % but not drill into individual records

**As COMPLIANCE_OFFICER**:
- Same Corridor Analytics tab, same query
- PII columns show full values (name, phone, email)
- Customer Risk tab shows drill-through to individual transactions
- SAR details visible

**As EXECUTIVE**:
- Corridor Analytics tab shows only top 5 corridors and KPI metrics
- No detail tables, no drill-through
- Total volume, total amount, top corridors -- the board-level view

**The demo point**: Switch roles in the sidebar. Watch the data change. The query didn't change. The semantic view didn't change. The governance policies from Workshop 1 are doing the work.

---

## Talk Track Snippets

> "The semantic view defines what 'transaction volume' means -- the join logic, the filters, the aggregation. That definition is enforced whether a human asks in English or a dashboard queries the view directly."

> "Notice: we didn't build three dashboards for three personas. We built one. The governance layer handles the differentiation. Add a new role next month -- update the masking policy, not the application."

> "Cortex Analyst is hitting the semantic view, not raw tables. That means every answer it gives is governed by the same contracts and policies you defined in Workshop 1. It can't see data the role shouldn't see."

---

## Takeaway

Participants leave Workshop 2 with:

- 4 semantic views exposing WU business concepts across source domains
- Cortex Analyst answering natural language questions against governed data
- A Streamlit dashboard proving role-based governance works end-to-end
- The foundation for quality monitoring in Workshop 3
