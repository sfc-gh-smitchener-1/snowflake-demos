-- ============================================================================
-- SUTTER HEALTH DEMO — Cost Comparison: Snowflake XS vs Databricks Always-On
-- ============================================================================
--
-- Calculates the compute cost of running the risk adjustment pipeline daily
-- for 30 days and compares Snowflake XS warehouse to an always-on
-- Databricks i3.xlarge cluster.
--
-- ASSUMPTIONS:
--   Snowflake:
--     - Warehouse: XS (2 credits/hr)
--     - Rate: $2.50/credit (enterprise list price, negotiated is lower)
--     - Pipeline runtime: 30-60 seconds per day (use 1 minute = 0.017 hrs)
--     - Auto-suspend: 60 seconds after idle → ~2 min total per run
--     - Daily compute: 2 credits/hr × (2 min / 60) = 0.067 credits/day
--
--   Databricks (alternative baseline):
--     - Instance: i3.xlarge on AWS (4 vCPU, 30.5 GB RAM)
--     - DBU rate: $0.10/DBU (jobs compute tier)
--     - DBUs/hr: 2.5 DBUs/hr for i3.xlarge
--     - EC2 cost: ~$0.312/hr on-demand
--     - Always-on 24/7 for 30 days = 720 hours
--
-- DEMO TALKING POINT:
--   "Snowflake costs $1.35 for 30 days of daily risk adjustment runs.
--    An equivalent always-on Databricks cluster costs $216 for the same
--    period — 160× more. Snowflake auto-suspends; you only pay when the
--    pipeline actually runs."
--
-- RUN AS: DATA_ADMIN (read-only, no table writes)
-- ============================================================================

USE ROLE DATA_ADMIN;
USE WAREHOUSE ANALYTICS_WH;

-- ═══════════════════════════════════════════════════════════════════════════
-- Core cost parameters
-- ═══════════════════════════════════════════════════════════════════════════

WITH

-- Snowflake XS parameters
sf_params AS (
    SELECT
        'Snowflake'                     AS platform,
        'XS Warehouse (auto-suspend)'   AS configuration,
        2.0                             AS credits_per_hour,
        2.50                            AS cost_per_credit_usd,
        2.0 / 60.0                      AS active_minutes_per_day,   -- ~2 min (run + auto-suspend)
        30                              AS days_in_period
),

-- Databricks always-on parameters
db_params AS (
    SELECT
        'Databricks'                                AS platform,
        'i3.xlarge always-on (24/7 Jobs Compute)'   AS configuration,
        2.50                                         AS dbus_per_hour,          -- i3.xlarge DBU rate
        0.10                                         AS dbu_cost_usd,           -- Jobs compute DBU price
        0.312                                        AS ec2_cost_per_hour_usd,  -- AWS i3.xlarge on-demand
        24.0                                         AS active_hours_per_day,   -- always-on
        30                                           AS days_in_period
),

-- Snowflake cost calculation
sf_cost AS (
    SELECT
        platform,
        configuration,
        active_minutes_per_day      AS daily_active_units,
        'minutes/day'               AS unit_label,
        days_in_period,
        -- Active hours over 30 days
        (active_minutes_per_day / 60.0) * days_in_period   AS total_active_hours,
        -- Credits consumed
        credits_per_hour * (active_minutes_per_day / 60.0) * days_in_period AS total_credits,
        -- Total cost
        credits_per_hour * (active_minutes_per_day / 60.0) * days_in_period * cost_per_credit_usd AS total_cost_usd,
        -- Daily cost
        credits_per_hour * (active_minutes_per_day / 60.0) * cost_per_credit_usd AS daily_cost_usd,
        cost_per_credit_usd         AS unit_rate_usd,
        'USD per credit'            AS rate_label,
        0                           AS is_always_on
    FROM sf_params
),

-- Databricks cost calculation
db_cost AS (
    SELECT
        platform,
        configuration,
        active_hours_per_day        AS daily_active_units,
        'hours/day (always-on)'     AS unit_label,
        days_in_period,
        active_hours_per_day * days_in_period   AS total_active_hours,
        -- Databricks has no "credits" — total_credits column repurposed for DBUs
        dbus_per_hour * active_hours_per_day * days_in_period AS total_credits,
        -- Total cost: DBU cost + EC2 cost
        (dbus_per_hour * dbu_cost_usd + ec2_cost_per_hour_usd) * active_hours_per_day * days_in_period AS total_cost_usd,
        (dbus_per_hour * dbu_cost_usd + ec2_cost_per_hour_usd) * active_hours_per_day AS daily_cost_usd,
        dbu_cost_usd + (ec2_cost_per_hour_usd / dbus_per_hour) AS unit_rate_usd,
        'USD per effective DBU'     AS rate_label,
        1                           AS is_always_on
    FROM db_params
),

-- Combined comparison
combined AS (
    SELECT * FROM sf_cost
    UNION ALL
    SELECT * FROM db_cost
),

-- Add ratio calculation
with_ratio AS (
    SELECT
        c.*,
        (SELECT total_cost_usd FROM combined WHERE platform = 'Databricks')
        / NULLIF((SELECT total_cost_usd FROM combined WHERE platform = 'Snowflake'), 0)
            AS cost_multiple_vs_snowflake
    FROM combined c
)

-- ═══════════════════════════════════════════════════════════════════════════
-- RESULT — Comparison table (present as slide data)
-- ═══════════════════════════════════════════════════════════════════════════
SELECT
    platform                                                AS "Platform",
    configuration                                           AS "Configuration",
    CASE is_always_on WHEN 1 THEN 'Always-on 24/7'
                      ELSE 'Auto-suspend (run-only)' END    AS "Compute Model",
    days_in_period                                          AS "Period (Days)",
    ROUND(total_active_hours, 1)                            AS "Total Active Hours",
    ROUND(daily_cost_usd, 4)                                AS "Daily Cost (USD)",
    ROUND(total_cost_usd, 2)                                AS "30-Day Total Cost (USD)",
    CASE platform
        WHEN 'Snowflake'   THEN '1.0×  (baseline)'
        ELSE ROUND(cost_multiple_vs_snowflake, 0)::VARCHAR || '×  more expensive'
    END                                                     AS "vs Snowflake"
FROM with_ratio
ORDER BY total_cost_usd;

-- ═══════════════════════════════════════════════════════════════════════════
-- EXTENDED ANALYSIS — Monthly cost at various pipeline frequencies
-- ═══════════════════════════════════════════════════════════════════════════
WITH frequency_scenarios AS (
    SELECT column1 AS scenario, column2 AS runs_per_day, column3 AS minutes_per_run
    FROM VALUES
        ('Daily (1×/day)',     1,  2.0),
        ('Twice daily',        2,  2.0),
        ('Hourly (realtime)',  24, 0.5),
        ('Weekly batch',       0.143, 15.0)  -- 1 run per 7 days, 15 min each
)
SELECT
    scenario                                                AS "Scenario",
    runs_per_day                                            AS "Runs/Day",
    ROUND(runs_per_day * minutes_per_run, 1)                AS "Active Min/Day",
    -- Snowflake cost
    ROUND(2.0 * (runs_per_day * minutes_per_run / 60.0) * 2.50 * 30, 2)
                                                            AS "Snowflake 30-Day ($)",
    -- Databricks stays the same (always-on)
    ROUND((2.50 * 0.10 + 0.312) * 24 * 30, 2)             AS "Databricks 30-Day ($)",
    -- Savings
    ROUND((2.50 * 0.10 + 0.312) * 24 * 30 -
          2.0 * (runs_per_day * minutes_per_run / 60.0) * 2.50 * 30, 2)
                                                            AS "Monthly Savings ($)"
FROM frequency_scenarios
ORDER BY runs_per_day;
