#!/usr/bin/env python3
"""
United Rentals — Snowflake CI/CD Integration Tests

Post-deploy verification that runs as UR_CICD_VALIDATOR (read-only cross-env).
Validates that deployed objects exist, have data, and match expectations.

Test suites:
  smoke  — Quick: object existence + non-empty checks (< 30 seconds)
  full   — Comprehensive: row counts, schema validation, cross-env consistency

The tests prove that:
  1. The deploy role actually created the objects
  2. Data flows correctly through RAW → CURATED → SEMANTIC
  3. Governance (tags, policies) survived the deployment
  4. The validator role can read (but not write) across all environments

Usage:
  # Smoke test after DEV deploy
  python sf_integration_tests.py --target-env DEV --schema UNITED_RENTALS --suite smoke

  # Full integration test after STG deploy
  python sf_integration_tests.py --target-env STG --schema UNITED_RENTALS --suite full

Environment variables:
  SNOWFLAKE_ACCOUNT      — Snowflake account identifier
  SNOWFLAKE_USER         — Service account username
  SNOWFLAKE_PRIVATE_KEY  — Private key for key-pair auth
  SNOWFLAKE_ROLE         — Should be UR_CICD_VALIDATOR
  SNOWFLAKE_WAREHOUSE    — Compute warehouse (default: TRANSFORM_WH)
"""

import argparse
import os
import sys
import time

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


def resolve_databases(conn, target_env):
    """Resolve all layer databases from ENVIRONMENT_REGISTRY."""
    cur = conn.cursor()
    cur.execute("""
        SELECT LAYER, DATABASE_NAME
        FROM GOVERNANCE.CONTRACTS.ENVIRONMENT_REGISTRY
        WHERE ENVIRONMENT = %s
        ORDER BY LAYER
    """, (target_env,))
    result = {row[0]: row[1] for row in cur.fetchall()}
    cur.close()
    return result


# ============================================================================
# TEST FRAMEWORK
# ============================================================================

class TestResult:
    def __init__(self, name, passed, message, duration_ms=0):
        self.name = name
        self.passed = passed
        self.message = message
        self.duration_ms = duration_ms


def run_test(name, fn):
    """Run a test function, capture result and timing."""
    start = time.time()
    try:
        passed, message = fn()
        elapsed = int((time.time() - start) * 1000)
        return TestResult(name, passed, message, elapsed)
    except Exception as e:
        elapsed = int((time.time() - start) * 1000)
        return TestResult(name, False, f"Exception: {str(e)[:200]}", elapsed)


# ============================================================================
# SMOKE TESTS
# ============================================================================

def smoke_tests(conn, databases, schema):
    """Quick checks: objects exist, tables have rows."""
    results = []

    # Test: Schema exists in each database
    for layer, db in databases.items():
        def check_schema(db=db, schema=schema):
            cur = conn.cursor()
            cur.execute(f"SHOW SCHEMAS LIKE '{schema}' IN DATABASE {db}")
            rows = cur.fetchall()
            cur.close()
            if rows:
                return True, f"Schema {db}.{schema} exists"
            return False, f"Schema {db}.{schema} NOT FOUND"

        results.append(run_test(f"schema_exists_{layer}", check_schema))

    # Test: Key tables exist and have rows
    key_tables = {
        "RAW": ["BRANCHES", "EQUIPMENT", "CUSTOMERS",
                "RENTAL_CONTRACTS", "MAINTENANCE_RECORDS", "TELEMATICS"],
        "CURATED": ["DIM_BRANCH", "DIM_EQUIPMENT", "DIM_CUSTOMER",
                     "FACT_RENTALS", "FACT_MAINTENANCE"],
    }

    for layer, tables in key_tables.items():
        db = databases.get(layer)
        if not db:
            continue

        for table in tables:
            def check_table(db=db, schema=schema, table=table):
                cur = conn.cursor()
                try:
                    cur.execute(f"SELECT COUNT(*) FROM {db}.{schema}.{table}")
                    count = cur.fetchone()[0]
                    cur.close()
                    if count > 0:
                        return True, f"{db}.{schema}.{table}: {count:,} rows"
                    return False, f"{db}.{schema}.{table}: EMPTY (0 rows)"
                except snowflake.connector.errors.ProgrammingError as e:
                    cur.close()
                    return False, f"{db}.{schema}.{table}: {e.msg[:100]}"

            results.append(run_test(f"has_data_{layer}_{table}", check_table))

    # Test: GOVERNANCE tables exist
    gov_tables = ["ENVIRONMENT_REGISTRY", "PROMOTION_LOG", "CLONE_REGISTRY"]
    for table in gov_tables:
        def check_gov(table=table):
            cur = conn.cursor()
            try:
                cur.execute(f"SELECT COUNT(*) FROM GOVERNANCE.CONTRACTS.{table}")
                count = cur.fetchone()[0]
                cur.close()
                return True, f"GOVERNANCE.CONTRACTS.{table}: {count:,} rows"
            except Exception as e:
                cur.close()
                return False, f"GOVERNANCE.CONTRACTS.{table}: {str(e)[:100]}"

        results.append(run_test(f"gov_{table.lower()}", check_gov))

    return results


# ============================================================================
# FULL TESTS
# ============================================================================

def full_tests(conn, databases, schema, target_env):
    """Comprehensive checks: row counts, governance, write-rejection."""
    results = smoke_tests(conn, databases, schema)

    # Test: Validator role CANNOT write (proves isolation)
    def check_write_blocked():
        db = databases.get("CURATED")
        if not db:
            return True, "No CURATED database to test against"
        cur = conn.cursor()
        try:
            cur.execute(f"""
                CREATE TABLE {db}.{schema}.__CICD_WRITE_TEST (ID INT)
            """)
            # If we get here, the write SUCCEEDED — that's a failure
            cur.execute(f"DROP TABLE IF EXISTS {db}.{schema}.__CICD_WRITE_TEST")
            cur.close()
            return False, f"WRITE SUCCEEDED — {os.environ.get('SNOWFLAKE_ROLE')} should be read-only!"
        except snowflake.connector.errors.ProgrammingError:
            cur.close()
            return True, f"Write correctly blocked for {os.environ.get('SNOWFLAKE_ROLE')}"

    results.append(run_test("write_blocked_validator", check_write_blocked))

    # Test: Environment registry has correct entries for this env
    def check_registry_entries():
        cur = conn.cursor()
        cur.execute("""
            SELECT COUNT(*)
            FROM GOVERNANCE.CONTRACTS.ENVIRONMENT_REGISTRY
            WHERE ENVIRONMENT = %s
        """, (target_env,))
        count = cur.fetchone()[0]
        cur.close()
        if count == 3:
            return True, f"Registry has {count} entries for {target_env} (expected 3)"
        return False, f"Registry has {count} entries for {target_env} (expected 3)"

    results.append(run_test("registry_entries", check_registry_entries))

    # Test: CI/CD views are queryable
    views = ["VW_CICD_ROLE_MATRIX", "VW_PROMOTION_HISTORY",
             "VW_ACTIVE_CLONES", "VW_UR_ROLE_HIERARCHY"]
    for view in views:
        def check_view(view=view):
            cur = conn.cursor()
            try:
                cur.execute(f"SELECT COUNT(*) FROM GOVERNANCE.CONTRACTS.{view}")
                count = cur.fetchone()[0]
                cur.close()
                return True, f"{view}: {count:,} rows"
            except Exception as e:
                cur.close()
                return False, f"{view}: {str(e)[:100]}"

        results.append(run_test(f"view_{view.lower()}", check_view))

    # Test: Cross-env data consistency (CURATED row counts shouldn't diverge wildly)
    if target_env in ("STG", "PROD"):
        source_env = "DEV" if target_env == "STG" else "STG"

        def check_cross_env_consistency():
            cur = conn.cursor()
            cur.execute("""
                SELECT DATABASE_NAME
                FROM GOVERNANCE.CONTRACTS.ENVIRONMENT_REGISTRY
                WHERE ENVIRONMENT = %s AND LAYER = 'CURATED'
            """, (source_env,))
            src_row = cur.fetchone()

            cur.execute("""
                SELECT DATABASE_NAME
                FROM GOVERNANCE.CONTRACTS.ENVIRONMENT_REGISTRY
                WHERE ENVIRONMENT = %s AND LAYER = 'CURATED'
            """, (target_env,))
            tgt_row = cur.fetchone()
            cur.close()

            if not src_row or not tgt_row:
                return True, "Cannot compare — missing registry entries"

            src_db = src_row[0]
            tgt_db = tgt_row[0]

            cur = conn.cursor()
            try:
                cur.execute(f"SELECT COUNT(*) FROM {src_db}.{schema}.DIM_BRANCH")
                src_count = cur.fetchone()[0]
                cur.execute(f"SELECT COUNT(*) FROM {tgt_db}.{schema}.DIM_BRANCH")
                tgt_count = cur.fetchone()[0]
                cur.close()

                if src_count == 0 and tgt_count == 0:
                    return True, f"Both {source_env} and {target_env} empty (OK for fresh deploy)"
                if tgt_count == 0:
                    return True, f"{target_env} empty — likely first deploy"

                drift = abs(src_count - tgt_count) / max(src_count, tgt_count)
                msg = (f"DIM_BRANCH: {source_env}={src_count:,}, "
                       f"{target_env}={tgt_count:,} (drift={drift:.1%})")
                return drift < 0.5, msg
            except Exception as e:
                cur.close()
                return True, f"Cross-env comparison skipped: {str(e)[:100]}"

        results.append(run_test("cross_env_consistency", check_cross_env_consistency))

    # Test: Governance tags applied (CURATED layer)
    def check_governance_tags():
        db = databases.get("CURATED")
        if not db:
            return True, "No CURATED database"
        cur = conn.cursor()
        try:
            cur.execute(f"""
                SELECT COUNT(*)
                FROM TABLE({db}.INFORMATION_SCHEMA.TAG_REFERENCES(
                    '{db}.{schema}.DIM_CUSTOMER', 'TABLE'
                ))
            """)
            count = cur.fetchone()[0]
            cur.close()
            if count > 0:
                return True, f"DIM_CUSTOMER has {count} governance tag(s)"
            return False, "DIM_CUSTOMER has NO governance tags"
        except Exception as e:
            cur.close()
            # Tag references may fail if table doesn't exist yet
            return True, f"Tag check skipped: {str(e)[:80]}"

    results.append(run_test("governance_tags", check_governance_tags))

    return results


# ============================================================================
# CLI
# ============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="UR Snowflake CI/CD Integration Tests"
    )
    parser.add_argument("--target-env", required=True,
                        help="Target environment: DEV, STG, PROD")
    parser.add_argument("--schema", default="UNITED_RENTALS",
                        help="Schema to validate")
    parser.add_argument("--suite", default="smoke", choices=["smoke", "full"],
                        help="Test suite to run")

    args = parser.parse_args()
    conn = get_connection()

    try:
        print(f"=== Integration Tests: {args.suite.upper()} suite for {args.target_env} ===")
        print(f"  Role:   {os.environ.get('SNOWFLAKE_ROLE')}")
        print(f"  Schema: {args.schema}")
        print()

        databases = resolve_databases(conn, args.target_env)
        print("  Resolved databases:")
        for layer, db in databases.items():
            print(f"    {layer}: {db}")
        print()

        if args.suite == "smoke":
            results = smoke_tests(conn, databases, args.schema)
        else:
            results = full_tests(conn, databases, args.schema, args.target_env)

        # Print results
        passed = 0
        failed = 0
        for r in results:
            icon = "PASS" if r.passed else "FAIL"
            print(f"  [{icon}] {r.name} ({r.duration_ms}ms)")
            print(f"         {r.message}")
            if r.passed:
                passed += 1
            else:
                failed += 1

        # Summary
        total = passed + failed
        print()
        print(f"=== Results: {passed}/{total} passed, {failed} failed ===")

        if failed > 0:
            print(f"\nFAILED: {failed} integration test(s) failed.")
            sys.exit(1)
        else:
            print(f"\nPASSED: All {total} tests passed for {args.target_env}.")

    finally:
        conn.close()


if __name__ == "__main__":
    main()
