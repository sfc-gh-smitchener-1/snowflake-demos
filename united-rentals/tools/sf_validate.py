#!/usr/bin/env python3
"""
United Rentals — Snowflake CI/CD Validation Script

Runs the VALIDATE_PROMOTION stored procedure for each data layer and reports
pass/fail results. Used as a GitHub Actions gate — any ERROR-severity failure
causes exit code 1, which blocks the pipeline.

Checks performed by VALIDATE_PROMOTION:
  1. ROLE_AUTHORIZATION  — Is the caller authorized for the target env?
  2. SOURCE_HAS_OBJECTS  — Does the source schema have objects?
  3. APPROVAL_REQUIRED   — Does the target require manual approval?
  4. TARGET_RESOLVED     — Can the registry resolve a target database?

Usage:
  # Standard validation (CI/CD pipeline)
  python sf_validate.py --target-env STG --layers RAW CURATED SEMANTIC \
    --schema UNITED_RENTALS

  # Strict mode (for PROD — any WARNING also fails)
  python sf_validate.py --target-env PROD --layers RAW CURATED SEMANTIC \
    --schema UNITED_RENTALS --strict

Environment variables:
  SNOWFLAKE_ACCOUNT      — Snowflake account identifier
  SNOWFLAKE_USER         — Service account username
  SNOWFLAKE_PRIVATE_KEY  — Private key for key-pair auth
  SNOWFLAKE_ROLE         — Should be UR_CICD_VALIDATOR for validation
  SNOWFLAKE_WAREHOUSE    — Compute warehouse (default: TRANSFORM_WH)
"""

import argparse
import os
import sys

try:
    import snowflake.connector
except ImportError:
    print("ERROR: snowflake-connector-python not installed.")
    print("  pip install snowflake-connector-python")
    sys.exit(1)


def get_connection():
    """Build a Snowflake connection from environment variables."""
    account = os.environ.get("SNOWFLAKE_ACCOUNT")
    user = os.environ.get("SNOWFLAKE_USER")
    role = os.environ.get("SNOWFLAKE_ROLE")
    warehouse = os.environ.get("SNOWFLAKE_WAREHOUSE", "TRANSFORM_WH")

    if not account or not user:
        print("ERROR: SNOWFLAKE_ACCOUNT and SNOWFLAKE_USER are required.")
        sys.exit(1)

    connect_args = {
        "account": account,
        "user": user,
        "role": role,
        "warehouse": warehouse,
    }

    private_key = os.environ.get("SNOWFLAKE_PRIVATE_KEY")
    password = os.environ.get("SNOWFLAKE_PASSWORD")

    if private_key:
        if os.path.isfile(private_key):
            with open(private_key, "rb") as f:
                private_key = f.read()
        connect_args["private_key"] = private_key
    elif password:
        connect_args["password"] = password
    else:
        print("ERROR: SNOWFLAKE_PRIVATE_KEY or SNOWFLAKE_PASSWORD required.")
        sys.exit(1)

    return snowflake.connector.connect(**connect_args)


# Map layer names to the source database prefix for DEV
LAYER_TO_SOURCE_PREFIX = {
    "RAW": "RAW",
    "CURATED": "CURATED",
    "SEMANTIC": "SEM",
}


def resolve_source_db(target_env, layer):
    """
    Determine the source database for validation.
    Promotion path: DEV → STG → PROD.
    """
    prefix = LAYER_TO_SOURCE_PREFIX[layer]
    if target_env == "STG":
        return f"{prefix}_DEV"
    elif target_env == "PROD":
        return f"{prefix}_STG"
    else:
        return f"{prefix}_DEV"


def validate_layer(conn, target_env, layer, schema):
    """
    Call VALIDATE_PROMOTION for a single layer and return the results.

    Returns list of dicts: {check_name, passed, message, severity}
    """
    source_db = resolve_source_db(target_env, layer)

    cur = conn.cursor()
    cur.execute("""
        CALL GOVERNANCE.CONTRACTS.VALIDATE_PROMOTION(%s, %s, %s)
    """, (source_db, target_env, schema))

    results = []
    for row in cur.fetchall():
        results.append({
            "check_name": row[0],
            "passed": row[1],
            "message": row[2],
            "severity": row[3],
        })

    cur.close()
    return results


def run_environment_registry_check(conn, target_env):
    """
    Verify that all three layers can be resolved from ENVIRONMENT_REGISTRY.
    This is a meta-check that the registry itself is healthy.
    """
    cur = conn.cursor()
    cur.execute("""
        SELECT LAYER, DATABASE_NAME, DEPLOY_ROLE
        FROM GOVERNANCE.CONTRACTS.ENVIRONMENT_REGISTRY
        WHERE ENVIRONMENT = %s
        ORDER BY LAYER
    """, (target_env,))

    rows = cur.fetchall()
    cur.close()

    expected_layers = {"RAW", "CURATED", "SEMANTIC"}
    found_layers = {row[0] for row in rows}
    missing = expected_layers - found_layers

    results = []
    if missing:
        results.append({
            "check_name": "REGISTRY_COMPLETENESS",
            "passed": False,
            "message": f"Missing registry entries for layers: {', '.join(missing)}",
            "severity": "ERROR",
        })
    else:
        results.append({
            "check_name": "REGISTRY_COMPLETENESS",
            "passed": True,
            "message": f"All 3 layers registered for {target_env}: "
                       + ", ".join(f"{r[0]}→{r[1]}" for r in rows),
            "severity": "INFO",
        })

    return results


def run_cross_env_row_count_check(conn, target_env, schema):
    """
    Compare row counts between source and target environments.
    Large discrepancies might indicate a problem.
    Only runs if both source and target have data.
    """
    results = []

    for layer in ("RAW", "CURATED"):
        source_db = resolve_source_db(target_env, layer)
        prefix = LAYER_TO_SOURCE_PREFIX[layer]

        # Resolve target database from registry
        cur = conn.cursor()
        cur.execute("""
            SELECT DATABASE_NAME
            FROM GOVERNANCE.CONTRACTS.ENVIRONMENT_REGISTRY
            WHERE ENVIRONMENT = %s AND LAYER = %s
        """, (target_env, layer))
        row = cur.fetchone()
        cur.close()

        if not row:
            continue

        target_db = row[0]

        # Get table names from source
        cur = conn.cursor()
        try:
            cur.execute(f"""
                SELECT TABLE_NAME
                FROM {source_db}.INFORMATION_SCHEMA.TABLES
                WHERE TABLE_SCHEMA = %s AND TABLE_TYPE = 'BASE TABLE'
                LIMIT 10
            """, (schema,))
            tables = [r[0] for r in cur.fetchall()]
        except Exception:
            tables = []
        cur.close()

        for table in tables:
            try:
                cur = conn.cursor()
                cur.execute(f"SELECT COUNT(*) FROM {source_db}.{schema}.{table}")
                src_count = cur.fetchone()[0]
                cur.close()

                cur = conn.cursor()
                cur.execute(f"SELECT COUNT(*) FROM {target_db}.{schema}.{table}")
                tgt_count = cur.fetchone()[0]
                cur.close()

                if src_count > 0 and tgt_count > 0:
                    drift = abs(src_count - tgt_count) / max(src_count, tgt_count)
                    results.append({
                        "check_name": f"ROW_COUNT_{layer}_{table}",
                        "passed": drift < 0.5,
                        "message": f"{source_db}.{table}: {src_count} rows, "
                                   f"{target_db}.{table}: {tgt_count} rows "
                                   f"(drift={drift:.1%})",
                        "severity": "WARNING" if drift >= 0.5 else "INFO",
                    })
            except Exception:
                # Table may not exist in target yet — that's fine
                pass

    return results


def print_results(layer_label, results):
    """Pretty-print validation results for a layer."""
    for r in results:
        icon = "PASS" if r["passed"] else "FAIL"
        severity = r["severity"]
        print(f"  [{icon}] [{severity}] {r['check_name']}: {r['message']}")


def main():
    parser = argparse.ArgumentParser(
        description="UR Snowflake CI/CD Validation — Promotion gate checks"
    )
    parser.add_argument("--target-env", required=True,
                        help="Target environment: DEV, STG, PROD")
    parser.add_argument("--layers", nargs="+", default=["RAW", "CURATED", "SEMANTIC"],
                        help="Data layers to validate")
    parser.add_argument("--schema", default="UNITED_RENTALS",
                        help="Schema name to validate")
    parser.add_argument("--strict", action="store_true",
                        help="Fail on WARNING severity (default: only ERROR fails)")

    args = parser.parse_args()

    conn = get_connection()

    all_results = []
    has_error = False
    has_warning = False

    try:
        # Meta-check: registry health
        print(f"=== Validation Gates for {args.target_env} ===")
        print(f"  Role: {os.environ.get('SNOWFLAKE_ROLE')}")
        print()

        print("--- Registry Health ---")
        reg_results = run_environment_registry_check(conn, args.target_env)
        print_results("REGISTRY", reg_results)
        all_results.extend(reg_results)
        print()

        # Per-layer validation via VALIDATE_PROMOTION
        for layer in args.layers:
            print(f"--- {layer} Layer ---")
            try:
                results = validate_layer(conn, args.target_env, layer, args.schema)
                print_results(layer, results)
                all_results.extend(results)
            except Exception as e:
                print(f"  [FAIL] [ERROR] VALIDATE_PROMOTION: {str(e)[:200]}")
                all_results.append({
                    "check_name": f"VALIDATE_PROMOTION_{layer}",
                    "passed": False,
                    "message": str(e)[:200],
                    "severity": "ERROR",
                })
            print()

        # Cross-env row count comparison (informational)
        print("--- Cross-Environment Row Counts ---")
        count_results = run_cross_env_row_count_check(conn, args.target_env, args.schema)
        if count_results:
            print_results("ROW_COUNTS", count_results)
            all_results.extend(count_results)
        else:
            print("  (no comparable tables found)")
        print()

        # Summary
        for r in all_results:
            if not r["passed"] and r["severity"] == "ERROR":
                has_error = True
            if not r["passed"] and r["severity"] == "WARNING":
                has_warning = True

        total = len(all_results)
        passed = sum(1 for r in all_results if r["passed"])
        failed = total - passed

        print("=== Summary ===")
        print(f"  Total checks: {total}")
        print(f"  Passed:       {passed}")
        print(f"  Failed:       {failed}")

        if has_error:
            print(f"\nBLOCKED: {args.target_env} deployment has ERROR-severity failures.")
            sys.exit(1)
        elif has_warning and args.strict:
            print(f"\nBLOCKED (strict mode): {args.target_env} deployment has WARNING-severity issues.")
            sys.exit(1)
        else:
            print(f"\nPASSED: All gates clear for {args.target_env} deployment.")

    finally:
        conn.close()


if __name__ == "__main__":
    main()
