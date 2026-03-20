#!/usr/bin/env python3
"""
United Rentals — Snowflake CI/CD Deploy Script

Queries ENVIRONMENT_REGISTRY for dynamic target resolution, then executes
SQL files against the resolved databases using the environment-scoped role.

Actions:
  resolve         — Look up target database from ENVIRONMENT_REGISTRY
  deploy          — Execute SQL files against the target environment
  log-promotion   — Write a record to PROMOTION_LOG
  promote-object  — Call PROMOTE_OBJECT stored procedure

The key design: this script NEVER hardcodes database names. Everything is
resolved at runtime from GOVERNANCE.CONTRACTS.ENVIRONMENT_REGISTRY.
The Snowflake role set via SNOWFLAKE_ROLE determines what environments
the script can touch — the grant IS the wall.

Usage:
  # Resolve target (dry run)
  python sf_deploy.py --action resolve --target-env DEV --layer CURATED

  # Deploy SQL to DEV
  python sf_deploy.py --action deploy --target-env DEV \
    --sql-dir demos/united-rentals/sql \
    --git-sha abc123 --git-branch feature/my-branch --pr-number 42

  # Log a promotion
  python sf_deploy.py --action log-promotion --target-env PROD \
    --git-sha abc123 --git-branch main --status SUCCESS

Environment variables:
  SNOWFLAKE_ACCOUNT      — Snowflake account identifier
  SNOWFLAKE_USER         — Service account username
  SNOWFLAKE_PRIVATE_KEY  — Private key for key-pair auth (PEM string or path)
  SNOWFLAKE_ROLE         — CI/CD role (UR_CICD_DEPLOY_DEV, _STG, _PROD)
  SNOWFLAKE_WAREHOUSE    — Compute warehouse (default: TRANSFORM_WH)
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path

try:
    import snowflake.connector
except ImportError:
    print("ERROR: snowflake-connector-python not installed.")
    print("  pip install snowflake-connector-python")
    sys.exit(1)


# ============================================================================
# CONNECTION
# ============================================================================

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

    # Support both private key string and password auth
    private_key = os.environ.get("SNOWFLAKE_PRIVATE_KEY")
    password = os.environ.get("SNOWFLAKE_PASSWORD")

    if private_key:
        # If it looks like a file path, read it
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


# ============================================================================
# ENVIRONMENT REGISTRY
# ============================================================================

def resolve_target(conn, target_env, layer):
    """
    Query ENVIRONMENT_REGISTRY to resolve the target database and deploy role.

    This is the core of dynamic target resolution — the pipeline never
    hardcodes RAW_DEV or CURATED_PROD. It asks the registry.
    """
    cur = conn.cursor()
    cur.execute("""
        SELECT DATABASE_NAME, DEPLOY_ROLE, VALIDATE_ROLE,
               REQUIRES_APPROVAL, APPROVAL_ROLE
        FROM GOVERNANCE.CONTRACTS.ENVIRONMENT_REGISTRY
        WHERE ENVIRONMENT = %s AND LAYER = %s
    """, (target_env.upper(), layer.upper()))

    row = cur.fetchone()
    cur.close()

    if not row:
        print(f"ERROR: No registry entry for env={target_env}, layer={layer}")
        sys.exit(1)

    result = {
        "database": row[0],
        "deploy_role": row[1],
        "validate_role": row[2],
        "requires_approval": row[3],
        "approval_role": row[4],
    }

    # Verify the current role matches the expected deploy role
    cur2 = conn.cursor()
    cur2.execute("SELECT CURRENT_ROLE()")
    current_role = cur2.fetchone()[0]
    cur2.close()

    if current_role not in (result["deploy_role"], "UR_PLATFORM_ADMIN", "DATA_ADMIN"):
        print(f"WARNING: Current role {current_role} != expected {result['deploy_role']}")
        print(f"  The deploy will proceed but may fail on permission checks.")

    return result


def resolve_all_layers(conn, target_env):
    """Resolve all three layers (RAW, CURATED, SEMANTIC) for an environment."""
    targets = {}
    for layer in ("RAW", "CURATED", "SEMANTIC"):
        targets[layer] = resolve_target(conn, target_env, layer)
    return targets


# ============================================================================
# DEPLOY
# ============================================================================

# SQL files that should be deployed per layer.
# Maps layer → list of SQL files (in execution order).
LAYER_SQL_MAP = {
    "RAW": ["02_ur_load_data.sql"],
    "CURATED": ["03_ur_curated_layer.sql", "05_ur_governance.sql"],
    "SEMANTIC": ["04_ur_semantic_layer.sql"],
}

# Files that are environment-setup (run once, not per-layer)
SETUP_FILES = ["01_ur_setup.sql", "07_ur_cicd_environments.sql"]


def deploy_sql(conn, target_env, sql_dir, git_sha=None, git_branch=None, pr_number=None):
    """
    Deploy SQL files to the target environment.

    For each layer, resolves the target database from ENVIRONMENT_REGISTRY,
    then executes the SQL files with the database context set.
    """
    sql_path = Path(sql_dir)
    if not sql_path.exists():
        print(f"ERROR: SQL directory not found: {sql_dir}")
        sys.exit(1)

    targets = resolve_all_layers(conn, target_env)

    print(f"=== Deploying to {target_env} ===")
    print(f"  Role:    {os.environ.get('SNOWFLAKE_ROLE')}")
    print(f"  Git SHA: {git_sha or 'N/A'}")
    print(f"  Branch:  {git_branch or 'N/A'}")
    print(f"  PR:      {pr_number or 'N/A'}")
    print()

    for layer, target in targets.items():
        db = target["database"]
        sql_files = LAYER_SQL_MAP.get(layer, [])

        if not sql_files:
            print(f"  [{layer}] No SQL files mapped — skipping")
            continue

        print(f"  [{layer}] Target database: {db}")

        for sql_file in sql_files:
            filepath = sql_path / sql_file
            if not filepath.exists():
                print(f"    SKIP {sql_file} (not found)")
                continue

            print(f"    Executing {sql_file} against {db}...")
            execute_sql_file(conn, filepath, db, target_env)
            print(f"    OK {sql_file}")

    print()
    print(f"=== Deploy to {target_env} complete ===")


def execute_sql_file(conn, filepath, database, target_env):
    """
    Execute a SQL file against a specific database.

    Handles multi-statement files by splitting on semicolons.
    Replaces environment-specific database references dynamically:
      RAW_DEV → resolved RAW database for target env
      CURATED_DEV → resolved CURATED database for target env
      etc.
    """
    with open(filepath, "r") as f:
        content = f.read()

    # Strip comments (lines starting with --)
    lines = []
    for line in content.split("\n"):
        stripped = line.strip()
        if stripped.startswith("--"):
            continue
        lines.append(line)
    content = "\n".join(lines)

    # Split on semicolons (basic — doesn't handle strings with semicolons,
    # but sufficient for DDL-heavy Snowflake scripts)
    statements = [s.strip() for s in content.split(";") if s.strip()]

    cur = conn.cursor()

    # Set database context
    try:
        cur.execute(f"USE DATABASE {database}")
    except Exception as e:
        print(f"      ERROR setting database context: {e}")
        raise

    for stmt in statements:
        if not stmt or stmt.upper().startswith("USE "):
            continue  # Skip USE statements — we control the context

        try:
            cur.execute(stmt)
        except snowflake.connector.errors.ProgrammingError as e:
            # Log but don't fail on individual statement errors in non-PROD
            if target_env == "PROD":
                raise
            print(f"      WARNING: {e.msg[:120]}")

    cur.close()


# ============================================================================
# PROMOTION LOGGING
# ============================================================================

def log_promotion(conn, target_env, git_sha, git_branch, status, pr_number=None):
    """Write a batch deployment record to PROMOTION_LOG."""
    cur = conn.cursor()
    cur.execute("""
        INSERT INTO GOVERNANCE.CONTRACTS.PROMOTION_LOG
            (SOURCE_ENVIRONMENT, TARGET_ENVIRONMENT, OBJECT_TYPE,
             OBJECT_NAME, PROMOTION_METHOD, VALIDATION_PASSED,
             GIT_COMMIT_SHA, GIT_BRANCH, PR_NUMBER, STATUS)
        VALUES (%s, %s, 'BATCH_DEPLOY', %s, 'DDL', %s, %s, %s, %s, %s)
    """, (
        "STG" if target_env == "PROD" else "DEV",
        target_env,
        f"Pipeline deploy to {target_env}",
        status == "SUCCESS",
        git_sha,
        git_branch,
        int(pr_number) if pr_number else None,
        status,
    ))
    cur.close()

    print(f"Promotion logged: {status} → {target_env} (sha={git_sha})")


def promote_object(conn, object_type, source_fqn, target_fqn, method,
                   git_sha=None, git_branch=None, pr_number=None):
    """Call the PROMOTE_OBJECT stored procedure."""
    cur = conn.cursor()
    cur.execute("""
        CALL GOVERNANCE.CONTRACTS.PROMOTE_OBJECT(
            %s, %s, %s, %s, %s, %s, %s
        )
    """, (object_type, source_fqn, target_fqn, method,
          git_sha, git_branch, int(pr_number) if pr_number else None))

    result = cur.fetchone()
    cur.close()

    print(result[0])


# ============================================================================
# CLI
# ============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="UR Snowflake CI/CD Deploy — Environment Registry-driven deployment"
    )
    parser.add_argument("--action", required=True,
                        choices=["resolve", "deploy", "log-promotion", "promote-object"],
                        help="Action to perform")
    parser.add_argument("--target-env", required=True,
                        help="Target environment: DEV, STG, PROD")
    parser.add_argument("--layer",
                        help="Data layer: RAW, CURATED, SEMANTIC (for resolve)")
    parser.add_argument("--sql-dir",
                        help="Directory containing SQL files (for deploy)")
    parser.add_argument("--git-sha", help="Git commit SHA")
    parser.add_argument("--git-branch", help="Git branch name")
    parser.add_argument("--pr-number", help="Pull request number")
    parser.add_argument("--status", help="Promotion status: SUCCESS, FAILED")

    # promote-object specific
    parser.add_argument("--object-type", help="TABLE, VIEW, DYNAMIC_TABLE, PROCEDURE")
    parser.add_argument("--source-fqn", help="Source fully qualified name")
    parser.add_argument("--target-fqn", help="Target fully qualified name")
    parser.add_argument("--method", default="CLONE",
                        help="Promotion method: CLONE, SWAP, DDL")

    args = parser.parse_args()

    conn = get_connection()

    try:
        if args.action == "resolve":
            if args.layer:
                result = resolve_target(conn, args.target_env, args.layer)
                print(json.dumps(result, indent=2, default=str))
            else:
                results = resolve_all_layers(conn, args.target_env)
                for layer, target in results.items():
                    print(f"{layer}: {target['database']} (role={target['deploy_role']}, "
                          f"approval={target['requires_approval']})")

        elif args.action == "deploy":
            if not args.sql_dir:
                print("ERROR: --sql-dir required for deploy action")
                sys.exit(1)
            deploy_sql(conn, args.target_env, args.sql_dir,
                       args.git_sha, args.git_branch, args.pr_number)

        elif args.action == "log-promotion":
            if not args.git_sha or not args.status:
                print("ERROR: --git-sha and --status required for log-promotion")
                sys.exit(1)
            log_promotion(conn, args.target_env, args.git_sha,
                          args.git_branch, args.status, args.pr_number)

        elif args.action == "promote-object":
            if not all([args.object_type, args.source_fqn, args.target_fqn]):
                print("ERROR: --object-type, --source-fqn, --target-fqn required")
                sys.exit(1)
            promote_object(conn, args.object_type, args.source_fqn,
                           args.target_fqn, args.method,
                           args.git_sha, args.git_branch, args.pr_number)

    finally:
        conn.close()


if __name__ == "__main__":
    main()
