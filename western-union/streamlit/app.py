"""
Western Union -- Trust Dashboard
Role-switching demo: same question, different answers per persona.
Demonstrates: Semantic Views + Governance + Quality Monitoring
"""

import streamlit as st
import pandas as pd
from datetime import datetime, timedelta
import random

st.set_page_config(page_title="WU Trust Dashboard", page_icon="\U0001f4b8", layout="wide")

# =============================================================================
# SNOWFLAKE CONNECTION
# =============================================================================

def get_session():
    """Attempt Snowflake connection; return None if unavailable."""
    try:
        from snowflake.snowpark.context import get_active_session
        return get_active_session()
    except Exception:
        return None

SESSION = get_session()

# =============================================================================
# ROLE DEFINITIONS
# =============================================================================

WU_ROLES = {
    "DATA_ANALYST": {
        "label": "Data Analyst",
        "desc": "Aggregated corridor volumes -- PII masked, full transaction data",
    },
    "COMPLIANCE_OFFICER": {
        "label": "Compliance Officer",
        "desc": "Full PII access -- drill-through to individual transactions + SAR details",
    },
    "EXECUTIVE": {
        "label": "Executive",
        "desc": "Top-level KPIs only -- total volume, top corridors, compliance hold %",
    },
}

CORRIDORS = [
    "US->MX", "US->IN", "US->PH", "US->GT", "UK->PK",
    "AE->IN", "US->CO", "DE->TR", "US->BD", "FR->MA",
]

COUNTRIES = ["US", "MX", "IN", "PH", "GT", "UK", "PK", "AE", "CO", "DE", "TR", "BD", "FR", "MA", "BR"]

# =============================================================================
# DEMO FALLBACK DATA
# =============================================================================

def _demo_corridor_data(role: str) -> pd.DataFrame:
    """Corridor analytics fallback -- content varies by role."""
    random.seed(42)
    rows = []
    for corridor in CORRIDORS:
        origin, dest = corridor.split("->")
        volume = random.randint(5000, 50000)
        amount = round(random.uniform(1_000_000, 25_000_000), 2)
        avg_amt = round(amount / volume, 2)
        hold_pct = round(random.uniform(0.5, 8.0), 2)
        rows.append({
            "CORRIDOR": corridor,
            "ORIGIN_COUNTRY": origin,
            "DESTINATION_COUNTRY": dest,
            "TRANSACTION_COUNT": volume,
            "TOTAL_AMOUNT_USD": amount,
            "AVG_TRANSACTION_USD": avg_amt,
            "COMPLIANCE_HOLD_PCT": hold_pct,
        })
    df = pd.DataFrame(rows)
    if role == "EXECUTIVE":
        return df[["CORRIDOR", "TRANSACTION_COUNT", "TOTAL_AMOUNT_USD"]].head(5)
    return df


def _demo_quality_data() -> dict:
    """Quality dashboard fallback data."""
    return {
        "freshness_score": 97.2,
        "completeness_score": 94.8,
        "accuracy_score": 99.1,
        "quarantine_count": 23,
        "contracts": pd.DataFrame([
            {"CONTRACT_ID": "CONTRACT-WU_PAYMENTS-FACT_TRANSACTIONS-001",
             "RULE": "Amount must be positive", "STATUS": "PASS", "VIOLATIONS": 0},
            {"CONTRACT_ID": "CONTRACT-WU_PAYMENTS-FACT_TRANSACTIONS-001",
             "RULE": "Corridor must not be null", "STATUS": "PASS", "VIOLATIONS": 0},
            {"CONTRACT_ID": "CONTRACT-WU_PAYMENTS-FACT_TRANSACTIONS-001",
             "RULE": "Status must be valid", "STATUS": "PASS", "VIOLATIONS": 0},
            {"CONTRACT_ID": "CONTRACT-WU_PAYMENTS-FACT_TRANSACTIONS-001",
             "RULE": "No structuring (amount < $3000 threshold)", "STATUS": "FAIL", "VIOLATIONS": 12},
            {"CONTRACT_ID": "CONTRACT-WU_KYC-DIM_CUSTOMER-001",
             "RULE": "KYC not stale (< 365 days)", "STATUS": "FAIL", "VIOLATIONS": 8},
            {"CONTRACT_ID": "CONTRACT-WU_KYC-DIM_CUSTOMER-001",
             "RULE": "Phone must be E.164 format", "STATUS": "FAIL", "VIOLATIONS": 15},
            {"CONTRACT_ID": "CONTRACT-WU_KYC-DIM_CUSTOMER-001",
             "RULE": "No expired-but-verified customers", "STATUS": "PASS", "VIOLATIONS": 0},
            {"CONTRACT_ID": "CONTRACT-WU_KYC-DIM_BENEFICIARY-001",
             "RULE": "Name must not be null", "STATUS": "PASS", "VIOLATIONS": 0},
            {"CONTRACT_ID": "CONTRACT-WU_KYC-DIM_BENEFICIARY-001",
             "RULE": "Country must be ISO-3166", "STATUS": "FAIL", "VIOLATIONS": 6},
            {"CONTRACT_ID": "CONTRACT-WU_KYC-DIM_BENEFICIARY-001",
             "RULE": "No duplicate beneficiaries per customer", "STATUS": "PASS", "VIOLATIONS": 0},
        ]),
        "quarantine": pd.DataFrame([
            {"RECORD_ID": "TXN-00412", "TABLE": "FACT_TRANSACTIONS",
             "REASON": "Suspected structuring: 3 txns totaling $2,980", "QUARANTINED_AT": "2025-01-15 09:23:00"},
            {"RECORD_ID": "TXN-00819", "TABLE": "FACT_TRANSACTIONS",
             "REASON": "Suspected structuring: 2 txns totaling $2,750", "QUARANTINED_AT": "2025-01-15 10:05:00"},
            {"RECORD_ID": "CUST-00156", "TABLE": "DIM_CUSTOMER",
             "REASON": "KYC expired > 365 days, still VERIFIED status", "QUARANTINED_AT": "2025-01-14 22:00:00"},
            {"RECORD_ID": "BEN-00234", "TABLE": "DIM_BENEFICIARY",
             "REASON": "Country code 'UK' not ISO-3166 (should be 'GB')", "QUARANTINED_AT": "2025-01-14 22:00:00"},
        ]),
        "remediation": pd.DataFrame([
            {"RECORD_ID": "BEN-00189", "TABLE": "DIM_BENEFICIARY", "FIELD": "COUNTRY",
             "OLD_VALUE": "UK", "NEW_VALUE": "GB", "METHOD": "AI (mistral-large)", "REMEDIATED_AT": "2025-01-14 23:15:00"},
            {"RECORD_ID": "CUST-00098", "TABLE": "DIM_CUSTOMER", "FIELD": "PHONE",
             "OLD_VALUE": "555-0123", "NEW_VALUE": "+15550123", "METHOD": "AI (mistral-large)", "REMEDIATED_AT": "2025-01-14 23:16:00"},
            {"RECORD_ID": "BEN-00201", "TABLE": "DIM_BENEFICIARY", "FIELD": "COUNTRY",
             "OLD_VALUE": "Philipines", "NEW_VALUE": "PH", "METHOD": "AI (mistral-large)", "REMEDIATED_AT": "2025-01-14 23:17:00"},
        ]),
    }


def _demo_customer_risk_data(role: str) -> pd.DataFrame:
    """Customer risk profile fallback."""
    random.seed(99)
    rows = []
    risk_levels = ["LOW", "MEDIUM", "HIGH", "CRITICAL"]
    kyc_statuses = ["VERIFIED", "PENDING", "EXPIRED"]
    for i in range(50):
        cid = f"CUST-{i:05d}"
        risk = random.choice(risk_levels)
        kyc = random.choice(kyc_statuses)
        sar_count = random.randint(0, 5) if risk in ("HIGH", "CRITICAL") else 0
        txn_count = random.randint(10, 500)
        total_sent = round(random.uniform(1000, 500000), 2)
        name = f"Customer {i}" if role == "COMPLIANCE_OFFICER" else "***MASKED***"
        rows.append({
            "CUSTOMER_ID": cid,
            "FULL_NAME": name,
            "RISK_LEVEL": risk,
            "KYC_STATUS": kyc,
            "SAR_COUNT": sar_count,
            "TRANSACTION_COUNT": txn_count,
            "TOTAL_SENT_USD": total_sent,
            "COUNTRY": random.choice(COUNTRIES),
        })
    return pd.DataFrame(rows)


def _demo_agent_scorecard_data() -> pd.DataFrame:
    """Agent compliance scorecard fallback."""
    random.seed(77)
    tiers = ["LOW", "MEDIUM", "HIGH", "CRITICAL"]
    rows = []
    for i in range(30):
        aid = f"AGT-{i:04d}"
        score = round(random.uniform(40, 100), 1)
        if score < 60:
            tier = "CRITICAL"
        elif score < 75:
            tier = "HIGH"
        elif score < 90:
            tier = "MEDIUM"
        else:
            tier = "LOW"
        rows.append({
            "AGENT_ID": aid,
            "AGENT_NAME": f"Agent Location {i}",
            "CITY": random.choice(["New York", "Los Angeles", "London", "Dubai", "Mumbai", "Manila", "Mexico City"]),
            "COUNTRY": random.choice(COUNTRIES),
            "COMPLIANCE_SCORE": score,
            "RISK_TIER": tier,
            "TRANSACTION_COUNT": random.randint(100, 5000),
            "SAR_COUNT": random.randint(0, 10) if tier in ("CRITICAL", "HIGH") else 0,
            "ACTIVE": random.choice([True, True, True, False]),
        })
    return pd.DataFrame(rows)


# =============================================================================
# DATA FUNCTIONS
# =============================================================================

@st.cache_data(ttl=60)
def fetch_corridor_data(role: str) -> pd.DataFrame:
    """Fetch corridor analytics from semantic view or fallback."""
    if SESSION is None:
        return _demo_corridor_data(role)
    try:
        df = SESSION.sql(
            "SELECT * FROM SEM_DEV.WU_REMITTANCE.TRANSACTION_VOLUME_BY_CORRIDOR"
        ).to_pandas()
        if role == "EXECUTIVE":
            agg = df.groupby("CORRIDOR").agg(
                TRANSACTION_COUNT=("TRANSACTION_COUNT", "sum"),
                TOTAL_AMOUNT_USD=("TOTAL_AMOUNT_USD", "sum"),
            ).reset_index().sort_values("TOTAL_AMOUNT_USD", ascending=False).head(5)
            return agg
        return df
    except Exception:
        return _demo_corridor_data(role)


@st.cache_data(ttl=60)
def fetch_quality_data() -> dict:
    """Fetch quality dashboard data or fallback."""
    if SESSION is None:
        return _demo_quality_data()
    try:
        result = SESSION.sql("CALL CURATED_DEV.WU_KYC.SP_WU_QUALITY_DASHBOARD_DATA()").to_pandas()
        # Parse stored procedure JSON output
        import json
        data = json.loads(result.iloc[0, 0])
        return {
            "freshness_score": data.get("freshness_score", 0),
            "completeness_score": data.get("completeness_score", 0),
            "accuracy_score": data.get("accuracy_score", 0),
            "quarantine_count": data.get("quarantine_count", 0),
            "contracts": pd.DataFrame(data.get("contracts", [])),
            "quarantine": pd.DataFrame(data.get("quarantine", [])),
            "remediation": pd.DataFrame(data.get("remediation", [])),
        }
    except Exception:
        return _demo_quality_data()


@st.cache_data(ttl=60)
def fetch_customer_risk(role: str) -> pd.DataFrame:
    """Fetch customer risk profiles from semantic view or fallback."""
    if SESSION is None:
        return _demo_customer_risk_data(role)
    try:
        return SESSION.sql(
            "SELECT * FROM SEM_DEV.WU_REMITTANCE.CUSTOMER_RISK_PROFILE"
        ).to_pandas()
    except Exception:
        return _demo_customer_risk_data(role)


@st.cache_data(ttl=60)
def fetch_agent_scorecard() -> pd.DataFrame:
    """Fetch agent compliance scorecard from semantic view or fallback."""
    if SESSION is None:
        return _demo_agent_scorecard_data()
    try:
        return SESSION.sql(
            "SELECT * FROM SEM_DEV.WU_REMITTANCE.AGENT_COMPLIANCE_SCORECARD"
        ).to_pandas()
    except Exception:
        return _demo_agent_scorecard_data()


# =============================================================================
# SIDEBAR
# =============================================================================

def render_sidebar() -> str:
    with st.sidebar:
        st.title("WU Trust Dashboard")
        st.caption("Western Union DCA Demo")
        st.divider()

        # Role Switcher
        st.subheader("Persona")
        current = st.session_state.get("wu_role", "DATA_ANALYST")
        role_keys = list(WU_ROLES.keys())
        idx = role_keys.index(current) if current in role_keys else 0

        selected = st.selectbox(
            "Active Role",
            role_keys,
            index=idx,
            format_func=lambda r: WU_ROLES[r]["label"],
        )
        st.session_state.wu_role = selected

        cfg = WU_ROLES.get(selected, {})
        st.markdown(f"**{cfg.get('desc', '')}**")

        # If connected, switch the actual Snowflake role
        if SESSION is not None:
            try:
                SESSION.sql(f"USE ROLE {selected}").collect()
                SESSION.sql("USE WAREHOUSE ANALYTICS_WH").collect()
            except Exception:
                pass

        st.divider()
        st.caption("Same data. Different answers. That's governance.")

    return selected


# =============================================================================
# TAB 1: CORRIDOR ANALYTICS
# =============================================================================

def render_corridor_analytics(role: str):
    st.header("Corridor Analytics")
    st.caption("The Semantic Layer in action -- one view, role-appropriate answers")

    df = fetch_corridor_data(role)
    if df.empty:
        st.warning("No corridor data available.")
        return

    if role == "EXECUTIVE":
        # Top-level KPIs only
        total_vol = df["TRANSACTION_COUNT"].sum()
        total_amt = df["TOTAL_AMOUNT_USD"].sum()

        k1, k2, k3 = st.columns(3)
        k1.metric("Total Transactions", f"{total_vol:,.0f}")
        k2.metric("Total Volume (USD)", f"${total_amt:,.0f}")
        k3.metric("Top Corridors Shown", len(df))

        st.subheader("Top 5 Corridors by Volume")
        st.dataframe(
            df,
            use_container_width=True,
            hide_index=True,
            column_config={
                "TOTAL_AMOUNT_USD": st.column_config.NumberColumn("Total USD", format="$%,.0f"),
                "TRANSACTION_COUNT": st.column_config.NumberColumn("Txn Count", format="%,d"),
            },
        )
    else:
        # Full corridor breakdown
        total_vol = df["TRANSACTION_COUNT"].sum()
        total_amt = df["TOTAL_AMOUNT_USD"].sum()
        avg_txn = df["AVG_TRANSACTION_USD"].mean() if "AVG_TRANSACTION_USD" in df.columns else 0
        hold_pct = df["COMPLIANCE_HOLD_PCT"].mean() if "COMPLIANCE_HOLD_PCT" in df.columns else 0

        k1, k2, k3, k4 = st.columns(4)
        k1.metric("Total Transactions", f"{total_vol:,.0f}")
        k2.metric("Total Volume (USD)", f"${total_amt:,.0f}")
        k3.metric("Avg Transaction", f"${avg_txn:,.2f}")
        k4.metric("Compliance Hold %", f"{hold_pct:.1f}%")

        st.dataframe(
            df,
            use_container_width=True,
            hide_index=True,
            column_config={
                "TOTAL_AMOUNT_USD": st.column_config.NumberColumn("Total USD", format="$%,.0f"),
                "AVG_TRANSACTION_USD": st.column_config.NumberColumn("Avg USD", format="$%,.2f"),
                "COMPLIANCE_HOLD_PCT": st.column_config.NumberColumn("Hold %", format="%.2f%%"),
                "TRANSACTION_COUNT": st.column_config.NumberColumn("Txn Count", format="%,d"),
            },
        )

        if role == "COMPLIANCE_OFFICER":
            st.info("As Compliance Officer, you can drill through to individual "
                    "transactions with full PII visibility via the Customer Risk tab.")


# =============================================================================
# TAB 2: DATA QUALITY
# =============================================================================

def render_data_quality():
    st.header("Data Quality")
    st.caption("The Contract in action -- automated validation, quarantine, and AI remediation")

    qdata = fetch_quality_data()

    # KPI row
    k1, k2, k3, k4 = st.columns(4)
    k1.metric("Freshness Score", f"{qdata['freshness_score']:.1f}%")
    k2.metric("Completeness Score", f"{qdata['completeness_score']:.1f}%")
    k3.metric("Accuracy Score", f"{qdata['accuracy_score']:.1f}%")
    k4.metric("Quarantined Records", qdata["quarantine_count"])

    st.divider()

    # Contract validation results
    st.subheader("Contract Validation Results")
    contracts_df = qdata.get("contracts", pd.DataFrame())
    if not contracts_df.empty:
        def status_color(val):
            if val == "PASS":
                return "background-color: #d4edda"
            return "background-color: #f8d7da"

        st.dataframe(
            contracts_df,
            use_container_width=True,
            hide_index=True,
            column_config={
                "STATUS": st.column_config.TextColumn("Status"),
                "VIOLATIONS": st.column_config.NumberColumn("Violations", format="%d"),
            },
        )
    else:
        st.info("No contract data available.")

    # Quarantine queue
    st.subheader("Quarantine Queue")
    quarantine_df = qdata.get("quarantine", pd.DataFrame())
    if not quarantine_df.empty:
        st.dataframe(quarantine_df, use_container_width=True, hide_index=True)
    else:
        st.success("No records currently quarantined.")

    # Remediation history
    st.subheader("AI Remediation History")
    remediation_df = qdata.get("remediation", pd.DataFrame())
    if not remediation_df.empty:
        st.dataframe(remediation_df, use_container_width=True, hide_index=True)
    else:
        st.info("No remediation actions recorded.")


# =============================================================================
# TAB 3: CUSTOMER RISK
# =============================================================================

def render_customer_risk(role: str):
    st.header("Customer Risk Profiles")
    st.caption("Cross-system intelligence -- KYC + Transactions + SARs in one view")

    df = fetch_customer_risk(role)
    if df.empty:
        st.warning("No customer risk data available.")
        return

    # Filters
    c1, c2 = st.columns(2)
    with c1:
        risk_filter = st.multiselect(
            "Risk Level",
            options=["LOW", "MEDIUM", "HIGH", "CRITICAL"],
            default=["HIGH", "CRITICAL"],
        )
    with c2:
        kyc_filter = st.multiselect(
            "KYC Status",
            options=["VERIFIED", "PENDING", "EXPIRED"],
            default=["VERIFIED", "PENDING", "EXPIRED"],
        )

    filtered = df[
        (df["RISK_LEVEL"].isin(risk_filter)) & (df["KYC_STATUS"].isin(kyc_filter))
    ]

    # KPIs
    k1, k2, k3, k4 = st.columns(4)
    k1.metric("Customers Shown", len(filtered))
    k2.metric("High/Critical Risk", len(filtered[filtered["RISK_LEVEL"].isin(["HIGH", "CRITICAL"])]))
    expired_active = filtered[
        (filtered["KYC_STATUS"] == "EXPIRED") & (filtered["TRANSACTION_COUNT"] > 0)
    ]
    k3.metric("Expired KYC + Active", len(expired_active))
    k4.metric("Total SARs", filtered["SAR_COUNT"].sum())

    # Highlight expired KYC customers still transacting
    if not expired_active.empty:
        st.warning(f"{len(expired_active)} customers have EXPIRED KYC but are still transacting.")
        with st.expander("View Expired KYC Customers"):
            st.dataframe(expired_active, use_container_width=True, hide_index=True)

    # Full table
    st.dataframe(
        filtered.sort_values("SAR_COUNT", ascending=False),
        use_container_width=True,
        hide_index=True,
        column_config={
            "TOTAL_SENT_USD": st.column_config.NumberColumn("Total Sent", format="$%,.0f"),
            "SAR_COUNT": st.column_config.NumberColumn("SARs"),
            "TRANSACTION_COUNT": st.column_config.NumberColumn("Txn Count", format="%,d"),
        },
    )


# =============================================================================
# TAB 4: AGENT HEALTH
# =============================================================================

def render_agent_health():
    st.header("Agent Compliance Scorecard")
    st.caption("Operational compliance -- agent network health at a glance")

    df = fetch_agent_scorecard()
    if df.empty:
        st.warning("No agent scorecard data available.")
        return

    # KPIs
    k1, k2, k3, k4 = st.columns(4)
    k1.metric("Total Agents", len(df))
    k2.metric("Critical Risk", len(df[df["RISK_TIER"] == "CRITICAL"]))
    k3.metric("High Risk", len(df[df["RISK_TIER"] == "HIGH"]))
    avg_score = df["COMPLIANCE_SCORE"].mean()
    k4.metric("Avg Compliance Score", f"{avg_score:.1f}")

    # Color-coded tier legend
    st.markdown(
        ":red[CRITICAL < 60] | "
        ":orange[HIGH 60-74] | "
        ":yellow[MEDIUM 75-89] | "
        ":green[LOW 90+]"
    )

    # Top 10 worst agents
    st.subheader("Bottom 10 Agents by Compliance Score")
    worst = df.sort_values("COMPLIANCE_SCORE", ascending=True).head(10)

    st.dataframe(
        worst,
        use_container_width=True,
        hide_index=True,
        column_config={
            "COMPLIANCE_SCORE": st.column_config.ProgressColumn(
                "Score", min_value=0, max_value=100, format="%.1f"
            ),
            "TRANSACTION_COUNT": st.column_config.NumberColumn("Txn Count", format="%,d"),
            "SAR_COUNT": st.column_config.NumberColumn("SARs"),
            "ACTIVE": st.column_config.CheckboxColumn("Active"),
        },
    )

    # Full table
    st.subheader("All Agents")
    st.dataframe(
        df.sort_values("COMPLIANCE_SCORE", ascending=True),
        use_container_width=True,
        hide_index=True,
        column_config={
            "COMPLIANCE_SCORE": st.column_config.ProgressColumn(
                "Score", min_value=0, max_value=100, format="%.1f"
            ),
            "TRANSACTION_COUNT": st.column_config.NumberColumn("Txn Count", format="%,d"),
            "SAR_COUNT": st.column_config.NumberColumn("SARs"),
            "ACTIVE": st.column_config.CheckboxColumn("Active"),
        },
    )


# =============================================================================
# MAIN
# =============================================================================

def main():
    role = render_sidebar()

    tab1, tab2, tab3, tab4 = st.tabs([
        "Corridor Analytics",
        "Data Quality",
        "Customer Risk",
        "Agent Health",
    ])

    with tab1:
        render_corridor_analytics(role)
    with tab2:
        render_data_quality()
    with tab3:
        render_customer_risk(role)
    with tab4:
        render_agent_health()


if __name__ == "__main__":
    main()
