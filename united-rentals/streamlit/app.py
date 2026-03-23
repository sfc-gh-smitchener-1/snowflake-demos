"""
United Rentals Fleet Finder — Streamlit in Snowflake (SiS)

Interactive fleet management demo with:
  - Page 1: Fleet Finder — find equipment by location, category, radius, and status
  - Page 2: Cortex Analyst — natural language fleet intelligence queries
  - RBAC Demo — role switcher with real Snowflake USE ROLE (RLS + masking)

Runs in Streamlit in Snowflake using only native packages:
  streamlit, pandas, snowflake.snowpark
"""

import streamlit as st
import pandas as pd
from snowflake.snowpark.context import get_active_session

# ============================================================================
# SESSION AND CONFIG
# ============================================================================

st.set_page_config(page_title="UR Fleet Finder", layout="wide")

session = get_active_session()

# Role metadata for the sidebar — governance is enforced by Snowflake, not app code
UR_ROLES = {
    "UR_FLEET_MANAGER": {
        "label": "Fleet Manager",
        "desc": "Full fleet visibility — all branches, all regions, all pricing",
    },
    "UR_REGIONAL_DIRECTOR": {
        "label": "Regional Director (SW)",
        "desc": "Southwest region only — full pricing",
    },
    "UR_BRANCH_MANAGER": {
        "label": "Branch Manager",
        "desc": "Branch-scoped — limited to assigned branches",
    },
    "UR_CORPORATE_ANALYST": {
        "label": "Corporate Analyst",
        "desc": "Cross-branch analytics — PII masked",
    },
    "UR_EXTERNAL_PARTNER": {
        "label": "External Partner",
        "desc": "Minimal access — no PII, no pricing",
    },
}

SEARCH_LOCATIONS = {
    "Dallas, TX": (32.7767, -96.7970),
    "Houston, TX": (29.7604, -95.3698),
    "Phoenix, AZ": (33.4484, -112.0740),
    "Chicago, IL": (41.8781, -87.6298),
    "Atlanta, GA": (33.7490, -84.3880),
    "Los Angeles, CA": (34.0522, -118.2437),
    "New York, NY": (40.7128, -74.0060),
    "Denver, CO": (39.7392, -104.9903),
    "Miami, FL": (25.7617, -80.1918),
    "Seattle, WA": (47.6062, -122.3321),
}

CATEGORIES = [
    "All", "AERIAL", "EARTHMOVING", "MATERIAL_HANDLING",
    "GENERAL_TOOLS", "POWER_AND_HVAC", "TRENCH_SAFETY",
]

MILES_TO_METERS = 1609.344

# ============================================================================
# ROLE MANAGEMENT — real Snowflake USE ROLE
# ============================================================================

def init_role():
    """Set the initial session role on first load."""
    if "ur_role" not in st.session_state:
        try:
            cur = session.sql("SELECT CURRENT_ROLE() AS R").to_pandas().iloc[0]["R"]
            if cur in UR_ROLES:
                st.session_state.ur_role = cur
                return
        except Exception:
            pass
        # Default to Fleet Manager
        try:
            session.sql("USE ROLE UR_FLEET_MANAGER").collect()
        except Exception:
            pass
        st.session_state.ur_role = "UR_FLEET_MANAGER"


def switch_role(role_name: str) -> bool:
    """Switch Snowflake session role. RLS and masking policies take effect immediately."""
    try:
        session.sql(f"USE ROLE {role_name}").collect()
        session.sql("USE WAREHOUSE ANALYTICS_WH").collect()
        st.session_state.ur_role = role_name
        return True
    except Exception as e:
        st.sidebar.error(f"Cannot switch to {role_name}: {e}")
        return False


def get_current_role() -> str:
    return st.session_state.get("ur_role", "UR_FLEET_MANAGER")


# ============================================================================
# DATA FUNCTIONS — no app-level filtering; Snowflake RLS handles scoping
# ============================================================================

def get_fleet_summary() -> pd.DataFrame:
    """Fleet-wide metrics visible to the current role."""
    sql = """
        SELECT
            COUNT(*) AS TOTAL_EQUIPMENT,
            COUNT_IF(STATUS = 'AVAILABLE') AS AVAILABLE,
            COUNT_IF(STATUS = 'RENTED') AS RENTED,
            COUNT_IF(STATUS = 'MAINTENANCE') AS IN_MAINTENANCE,
            COUNT(DISTINCT BRANCH_ID) AS BRANCHES,
            COUNT(DISTINCT REGION) AS REGIONS,
            ROUND(COUNT_IF(STATUS = 'RENTED') * 100.0
                  / NULLIF(COUNT(*), 0), 1) AS UTILIZATION_PCT
        FROM CURATED_DEV.UNITED_RENTALS.FLEET_AVAILABILITY
    """
    try:
        return session.sql(sql).to_pandas()
    except Exception as e:
        st.error(f"Fleet summary failed — check role grants: {e}")
        return pd.DataFrame()


def search_equipment(lat: float, lon: float, radius_miles: float,
                     category: str = "All",
                     status: str = "Available") -> pd.DataFrame:
    """Find equipment within radius. Snowflake RLS scopes results to the role."""
    radius_m = radius_miles * MILES_TO_METERS

    filters = [
        f"ST_DISTANCE(EQUIPMENT_LOCATION, ST_MAKEPOINT({lon}, {lat})) <= {radius_m}"
    ]
    if status == "Available":
        filters.append("STATUS = 'AVAILABLE'")
    elif status == "Rented":
        filters.append("STATUS = 'RENTED'")
    elif status == "Maintenance":
        filters.append("STATUS = 'MAINTENANCE'")
    if category and category != "All":
        filters.append(f"CATEGORY = '{category}'")

    where = " AND ".join(filters)

    sql = f"""
        SELECT
            EQUIPMENT_ID, MAKE, MODEL, CATEGORY, STATUS, CONDITION,
            EQUIPMENT_LAT, EQUIPMENT_LON,
            DAILY_RATE, WEEKLY_RATE, MONTHLY_RATE,
            BRANCH_NAME, BRANCH_CITY, BRANCH_STATE, REGION,
            FUEL_LEVEL_PCT, FAULT_CODE,
            ROUND(ST_DISTANCE(
                EQUIPMENT_LOCATION, ST_MAKEPOINT({lon}, {lat})
            ) / {MILES_TO_METERS}, 1) AS DISTANCE_MILES
        FROM CURATED_DEV.UNITED_RENTALS.FLEET_AVAILABILITY
        WHERE {where}
        ORDER BY DISTANCE_MILES ASC
        LIMIT 200
    """
    try:
        return session.sql(sql).to_pandas()
    except Exception as e:
        st.error(f"Search failed — check role grants on FLEET_AVAILABILITY: {e}")
        return pd.DataFrame()


def get_branch_summary() -> pd.DataFrame:
    """Branch-level equipment counts. RLS scopes to the role's allowed branches."""
    sql = """
        SELECT
            b.BRANCH_ID, b.BRANCH_NAME, b.CITY, b.STATE,
            b.LATITUDE, b.LONGITUDE, b.REGION,
            COUNT(e.EQUIPMENT_ID) AS TOTAL_EQUIPMENT,
            COUNT_IF(e.STATUS = 'AVAILABLE') AS AVAILABLE,
            COUNT_IF(e.STATUS = 'RENTED') AS RENTED,
            COUNT_IF(e.STATUS = 'MAINTENANCE') AS IN_MAINTENANCE
        FROM CURATED_DEV.UNITED_RENTALS.DIM_BRANCH b
        LEFT JOIN CURATED_DEV.UNITED_RENTALS.DIM_EQUIPMENT e
            ON b.BRANCH_ID = e.BRANCH_ID
        GROUP BY b.BRANCH_ID, b.BRANCH_NAME, b.CITY, b.STATE,
                 b.LATITUDE, b.LONGITUDE, b.REGION
        ORDER BY TOTAL_EQUIPMENT DESC
    """
    try:
        return session.sql(sql).to_pandas()
    except Exception as e:
        st.error(f"Branch summary failed: {e}")
        return pd.DataFrame()


# ============================================================================
# CORTEX ANALYST
# ============================================================================

def call_cortex_analyst(prompt: str, semantic_view: str):
    """Call Cortex Analyst API for natural language to SQL."""
    try:
        response = session._conn._rest.request(
            url="/api/v2/cortex/analyst/message",
            method="POST",
            body={
                "messages": [
                    {"role": "user", "content": [{"type": "text", "text": prompt}]}
                ],
                "semantic_view": semantic_view,
            },
            headers={"Content-Type": "application/json"},
        )
        if response and "message" in response:
            return response, None
        return None, "Empty response from Cortex Analyst"
    except Exception as e:
        return None, str(e)


def parse_analyst_response(response: dict):
    """Extract SQL and text from Cortex Analyst response."""
    sql = None
    text_parts = []
    if response and "message" in response:
        for item in response["message"].get("content", []):
            if item.get("type") == "sql":
                sql = item.get("statement", "")
            elif item.get("type") == "text":
                text_parts.append(item.get("text", ""))
    return sql, "\n".join(text_parts)


def _auto_map(df: pd.DataFrame):
    """Render a map if the dataframe has lat/lon columns."""
    lat_cols = [c for c in df.columns if "LAT" in c.upper()]
    lon_cols = [c for c in df.columns if "LON" in c.upper()]
    if lat_cols and lon_cols:
        m = df.rename(columns={lat_cols[0]: "latitude", lon_cols[0]: "longitude"})
        m = m.dropna(subset=["latitude", "longitude"])
        if not m.empty:
            st.map(m[["latitude", "longitude"]])


# ============================================================================
# SIDEBAR
# ============================================================================

def render_sidebar():
    with st.sidebar:
        st.title("UR Fleet Finder")
        st.caption("United Rentals DCA Demo")
        st.divider()

        # Role Switcher — actually switches Snowflake session role
        st.subheader("RBAC Role")
        current = get_current_role()
        role_keys = list(UR_ROLES.keys())
        idx = role_keys.index(current) if current in role_keys else 0

        selected = st.selectbox(
            "Active Role",
            role_keys,
            index=idx,
            format_func=lambda r: UR_ROLES[r]["label"],
        )
        if selected != current:
            if switch_role(selected):
                st.rerun()

        cfg = UR_ROLES.get(current, {})
        st.markdown(f"**{cfg.get('desc', '')}**")

        # Live access summary from Snowflake (proves RLS is working)
        try:
            row = session.sql("""
                SELECT COUNT(DISTINCT REGION) AS R, COUNT(DISTINCT BRANCH_ID) AS B
                FROM CURATED_DEV.UNITED_RENTALS.FLEET_AVAILABILITY
            """).to_pandas().iloc[0]
            st.caption(f"Visible: {int(row['R'])} regions, {int(row['B'])} branches")
        except Exception:
            st.caption("Visible: checking...")

        st.divider()
        page = st.radio("Page", ["Fleet Finder", "Cortex Analyst"],
                        label_visibility="collapsed")
        return page


# ============================================================================
# PAGE 1: FLEET FINDER
# ============================================================================

def render_fleet_finder():
    st.header("Fleet Finder")

    # Search controls
    c1, c2, c3, c4 = st.columns([2, 1, 1, 1])
    with c1:
        location = st.selectbox("Search Near", list(SEARCH_LOCATIONS.keys()))
    with c2:
        radius = st.slider("Radius (mi)", 10, 250, 100)
    with c3:
        category = st.selectbox("Category", CATEGORIES)
    with c4:
        status = st.selectbox("Status", ["Available", "Rented", "Maintenance", "All"])

    lat, lon = SEARCH_LOCATIONS[location]

    # Fleet-wide metrics
    summary = get_fleet_summary()
    if not summary.empty:
        s = summary.iloc[0]
        m1, m2, m3, m4, m5, m6 = st.columns(6)
        m1.metric("Branches", int(s.get("BRANCHES", 0)))
        m2.metric("Equipment", int(s.get("TOTAL_EQUIPMENT", 0)))
        m3.metric("Available", int(s.get("AVAILABLE", 0)))
        m4.metric("On Rent", int(s.get("RENTED", 0)))
        m5.metric("In Service", int(s.get("IN_MAINTENANCE", 0)))
        m6.metric("Utilization", f"{s.get('UTILIZATION_PCT', 0)}%")

    # Auto-search on every render — no click gate
    results = search_equipment(lat, lon, radius, category, status)

    # Results in tabs
    map_tab, table_tab, branch_tab = st.tabs(["Map", "Equipment List", "Branches"])

    with map_tab:
        if not results.empty:
            label = status if status != "All" else "total"
            st.success(f"**{len(results)}** {label.lower()} equipment within "
                       f"**{radius} mi** of {location}")
            map_data = results.rename(columns={
                "EQUIPMENT_LAT": "latitude", "EQUIPMENT_LON": "longitude"})
            st.map(map_data[["latitude", "longitude"]], zoom=6)
        else:
            st.warning(f"No equipment found within {radius} mi of {location} "
                       f"for the current filters and role.")

    with table_tab:
        if not results.empty:
            cols = [
                "EQUIPMENT_ID", "MAKE", "MODEL", "CATEGORY", "STATUS",
                "CONDITION", "BRANCH_NAME", "REGION", "DISTANCE_MILES",
                "DAILY_RATE", "WEEKLY_RATE", "MONTHLY_RATE",
                "FUEL_LEVEL_PCT", "FAULT_CODE",
            ]
            visible = [c for c in cols if c in results.columns]
            st.dataframe(
                results[visible],
                use_container_width=True,
                hide_index=True,
                column_config={
                    "DAILY_RATE": st.column_config.NumberColumn("Daily $", format="$%.0f"),
                    "WEEKLY_RATE": st.column_config.NumberColumn("Weekly $", format="$%.0f"),
                    "MONTHLY_RATE": st.column_config.NumberColumn("Monthly $", format="$%.0f"),
                    "DISTANCE_MILES": st.column_config.NumberColumn("Dist (mi)", format="%.1f"),
                    "FUEL_LEVEL_PCT": st.column_config.ProgressColumn(
                        "Fuel %", min_value=0, max_value=100),
                },
            )
        else:
            st.info("No equipment matches the current filters.")

    with branch_tab:
        branches = get_branch_summary()
        if not branches.empty:
            st.dataframe(
                branches[["BRANCH_NAME", "CITY", "STATE", "REGION",
                           "TOTAL_EQUIPMENT", "AVAILABLE", "RENTED", "IN_MAINTENANCE"]],
                use_container_width=True,
                hide_index=True,
            )
        else:
            st.info("No branches visible for the current role.")


# ============================================================================
# PAGE 2: CORTEX ANALYST
# ============================================================================

def render_cortex_page():
    st.header("Fleet Intelligence — Cortex Analyst")

    sv_options = {
        "FLEET_FINDER": "SEM_DEV.UNITED_RENTALS.FLEET_FINDER",
        "RENTAL_ANALYTICS": "SEM_DEV.UNITED_RENTALS.RENTAL_ANALYTICS",
    }
    selected_sv = st.selectbox("Semantic View", list(sv_options.keys()))
    semantic_view = sv_options[selected_sv]

    samples = {
        "FLEET_FINDER": [
            "How many pieces of equipment are available by category?",
            "Show me available aerial equipment in the Southwest",
            "Which branches have the most idle equipment?",
            "What is the average daily rate by category?",
        ],
        "RENTAL_ANALYTICS": [
            "What is total rental revenue by region?",
            "Average rental duration by equipment category",
            "Which customers have the highest rental spend?",
            "How many active contracts are there by region?",
        ],
    }

    cols = st.columns(len(samples[selected_sv]))
    for i, q in enumerate(samples[selected_sv]):
        with cols[i]:
            if st.button(q, key=f"s_{i}", use_container_width=True):
                st.session_state.analyst_input = q

    if "analyst_history" not in st.session_state:
        st.session_state.analyst_history = []

    for entry in st.session_state.analyst_history:
        with st.chat_message("user"):
            st.write(entry["question"])
        with st.chat_message("assistant"):
            if entry.get("text"):
                st.write(entry["text"])
            if entry.get("sql"):
                with st.expander("SQL"):
                    st.code(entry["sql"], language="sql")
            if entry.get("results") is not None and not entry["results"].empty:
                st.dataframe(entry["results"], use_container_width=True, hide_index=True)
                _auto_map(entry["results"])
            if entry.get("error"):
                st.error(entry["error"])

    default_input = st.session_state.pop("analyst_input", "")
    prompt = st.chat_input("Ask about fleet or rentals...")
    if default_input and not prompt:
        prompt = default_input

    if prompt:
        with st.chat_message("user"):
            st.write(prompt)
        with st.chat_message("assistant"):
            with st.spinner("Thinking..."):
                response, error = call_cortex_analyst(prompt, semantic_view)

            entry = {"question": prompt, "text": None, "sql": None,
                     "results": None, "error": None}

            if error:
                st.error(f"Cortex Analyst error: {error}")
                entry["error"] = error
            elif response:
                sql, text = parse_analyst_response(response)
                if text:
                    st.write(text)
                    entry["text"] = text
                if sql:
                    with st.expander("SQL"):
                        st.code(sql, language="sql")
                    entry["sql"] = sql
                    try:
                        result_df = session.sql(sql).to_pandas()
                        st.dataframe(result_df, use_container_width=True,
                                     hide_index=True)
                        entry["results"] = result_df
                        _auto_map(result_df)
                    except Exception as e:
                        st.error(f"SQL error: {e}")
                        entry["error"] = str(e)

            st.session_state.analyst_history.append(entry)

    if st.session_state.analyst_history:
        if st.button("Clear History"):
            st.session_state.analyst_history = []
            st.rerun()


# ============================================================================
# MAIN
# ============================================================================

def main():
    init_role()
    page = render_sidebar()
    if page == "Fleet Finder":
        render_fleet_finder()
    elif page == "Cortex Analyst":
        render_cortex_page()


if __name__ == "__main__":
    main()
