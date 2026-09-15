#!/usr/bin/env python3
"""
Sutter Health Demo — Deployment Script
End-to-end: generate data → PUT to stage → COPY INTO → run SQL scripts 01-07
"""

import os
import sys
import argparse
import subprocess
import glob as glob_module
from pathlib import Path

# Add the core tools path for _run_sql.py
DEMO_ROOT = Path(__file__).parent.parent
REPO_ROOT  = DEMO_ROOT.parent.parent
sys.path.insert(0, str(REPO_ROOT / 'tools'))

try:
    import snowflake.connector
except ImportError:
    print("ERROR: snowflake-connector-python not installed. Run: pip install snowflake-connector-python")
    sys.exit(1)

# ─── SQL scripts to execute in order ────────────────────────────────────────
SQL_SCRIPTS = [
    '01_sh_setup.sql',
    '02_sh_claims_model.sql',
    '03_sh_load_data.sql',
    '04_sh_curated_layer.sql',
    '05_sh_risk_adjustment_sp.sql',
    '06_sh_semantic_layer.sql',
    '07_sh_cost_comparison.sql',
]

DATA_FILES = [
    'member_enrollment.csv',
    'provider_directory.csv',
    'raw_claims.csv',
    'risk_adjustment_flags.csv',
    'claims_summary.csv',
]

STAGE_PATH = '@RAW_DEV.STAGING.DATA_STAGE/sutter_health/'


# ─── Helpers ────────────────────────────────────────────────────────────────

def connect(args) -> snowflake.connector.SnowflakeConnection:
    kwargs = dict(
        account   = args.account   or os.environ.get('SNOWFLAKE_ACCOUNT'),
        user      = args.user      or os.environ.get('SNOWFLAKE_USER'),
        warehouse = 'TRANSFORM_WH',
        role      = 'DATA_ADMIN',
        database  = 'RAW_DEV',
    )
    if args.password or os.environ.get('SNOWFLAKE_PASSWORD'):
        kwargs['password'] = args.password or os.environ['SNOWFLAKE_PASSWORD']
    elif args.private_key_path or os.environ.get('SNOWFLAKE_PRIVATE_KEY_PATH'):
        from snowflake.connector.network import DEFAULT_AUTHENTICATOR
        with open(args.private_key_path or os.environ['SNOWFLAKE_PRIVATE_KEY_PATH'], 'rb') as f:
            from cryptography.hazmat.backends import default_backend
            from cryptography.hazmat.primitives.serialization import load_pem_private_key
            private_key = load_pem_private_key(f.read(), password=None, backend=default_backend())
            from cryptography.hazmat.primitives.serialization import Encoding, PrivateFormat, NoEncryption
            kwargs['private_key'] = private_key.private_bytes(Encoding.DER, PrivateFormat.PKCS8, NoEncryption())
    else:
        kwargs['authenticator'] = 'externalbrowser'

    print(f"Connecting to Snowflake: {kwargs['account']} as {kwargs['user']}...")
    return snowflake.connector.connect(**kwargs)


def run_sql_file(conn, filepath: str, dry_run: bool = False) -> bool:
    """Execute a SQL file, handling BEGIN/END stored procedure blocks."""
    print(f"\n  Running {os.path.basename(filepath)} ...", end='', flush=True)
    if dry_run:
        print(" [DRY RUN]")
        return True

    with open(filepath, 'r') as f:
        content = f.read()

    # Split on semicolons but preserve BEGIN/END blocks (stored procedures)
    statements = _split_sql(content)
    cur = conn.cursor()
    errors = 0
    for stmt in statements:
        stmt = stmt.strip()
        if not stmt or stmt.startswith('--'):
            continue
        try:
            cur.execute(stmt)
        except Exception as e:
            print(f"\n    WARN: {e}")
            errors += 1
    cur.close()
    print(f" ✓ ({len(statements)} statements, {errors} warnings)")
    return errors == 0


def _split_sql(content: str):
    """Split SQL content into individual statements, respecting BEGIN/END blocks."""
    statements = []
    current    = []
    depth      = 0

    for line in content.splitlines():
        stripped = line.strip().upper()
        if stripped.startswith('BEGIN'):
            depth += 1
        if depth > 0 and stripped in ('END', 'END;', 'END$$', '$$'):
            depth -= 1

        current.append(line)
        if depth == 0 and line.rstrip().endswith(';'):
            stmt = '\n'.join(current).strip().rstrip(';')
            if stmt:
                statements.append(stmt)
            current = []

    if current:
        stmt = '\n'.join(current).strip().rstrip(';')
        if stmt:
            statements.append(stmt)

    return statements


def put_files(conn, data_dir: str, dry_run: bool = False) -> bool:
    """Upload CSV files to Snowflake internal stage."""
    cur = conn.cursor()
    success = True
    for filename in DATA_FILES:
        filepath = os.path.join(data_dir, filename)
        if not os.path.exists(filepath):
            print(f"  SKIP: {filename} not found in {data_dir}")
            continue
        print(f"  PUT  {filename} → {STAGE_PATH} ...", end='', flush=True)
        if dry_run:
            print(" [DRY RUN]")
            continue
        try:
            cur.execute(f"PUT file://{os.path.abspath(filepath)} {STAGE_PATH} AUTO_COMPRESS=TRUE OVERWRITE=TRUE")
            print(" ✓")
        except Exception as e:
            print(f"\n  ERROR: {e}")
            success = False
    cur.close()
    return success


# ─── Main ───────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description='Deploy Sutter Health DCA demo end-to-end')
    parser.add_argument('--account',          help='Snowflake account identifier')
    parser.add_argument('--user',             help='Snowflake username')
    parser.add_argument('--password',         help='Snowflake password (or set SNOWFLAKE_PASSWORD)')
    parser.add_argument('--private-key-path', dest='private_key_path', help='Path to RSA private key PEM')
    parser.add_argument('--data-dir',   default=str(DEMO_ROOT / 'data'), help='Directory with CSV files')
    parser.add_argument('--sql-dir',    default=str(DEMO_ROOT / 'sql'),  help='Directory with SQL scripts')
    parser.add_argument('--skip-data-gen',    action='store_true', help='Skip data generation step')
    parser.add_argument('--skip-upload',      action='store_true', help='Skip stage upload step')
    parser.add_argument('--skip-sql',         action='store_true', help='Skip SQL execution step')
    parser.add_argument('--sql-only',         action='store_true', help='Run SQL scripts only (no data gen/upload)')
    parser.add_argument('--dry-run',          action='store_true', help='Parse and validate only, no execution')
    parser.add_argument('--quick',            action='store_true', help='Generate 10%% sample data')
    parser.add_argument('--scale',   type=float, default=1.0,      help='Data scale factor')
    args = parser.parse_args()

    print("═" * 60)
    print("  Sutter Health DCA Demo — Deployment")
    print("═" * 60)

    # ── Phase 1: Generate data ──────────────────────────────────────────
    if not args.skip_data_gen and not args.sql_only:
        print("\n[1/3] Generating synthetic claims data...")
        gen_cmd = [sys.executable,
                   str(DEMO_ROOT / 'tools' / 'generate_sh_claims_data.py'),
                   '--output', args.data_dir]
        if args.quick:
            gen_cmd.append('--quick')
        if args.scale != 1.0:
            gen_cmd.extend(['--scale', str(args.scale)])
        if not args.dry_run:
            result = subprocess.run(gen_cmd, check=True)
        else:
            print(f"  [DRY RUN] Would run: {' '.join(gen_cmd)}")
    else:
        print("\n[1/3] Skipping data generation.")

    # ── Phase 2: Connect to Snowflake ───────────────────────────────────
    conn = None
    if not args.dry_run:
        conn = connect(args)

    # ── Phase 3: Upload to stage ────────────────────────────────────────
    if not args.skip_upload and not args.sql_only:
        print(f"\n[2/3] Uploading CSV files to {STAGE_PATH}...")
        if conn:
            put_files(conn, args.data_dir, dry_run=args.dry_run)
    else:
        print("\n[2/3] Skipping stage upload.")

    # ── Phase 4: Execute SQL scripts ────────────────────────────────────
    if not args.skip_sql:
        print(f"\n[3/3] Executing {len(SQL_SCRIPTS)} SQL scripts...")
        for script_name in SQL_SCRIPTS:
            script_path = os.path.join(args.sql_dir, script_name)
            if not os.path.exists(script_path):
                print(f"  MISSING: {script_path} — skipping")
                continue
            run_sql_file(conn, script_path, dry_run=args.dry_run)
    else:
        print("\n[3/3] Skipping SQL execution.")

    if conn:
        conn.close()

    print("\n" + "═" * 60)
    print("  Deployment complete.")
    print("  Next: CALL RAW_DEV.SUTTER_HEALTH.SP_SH_RISK_ADJUSTMENT_DAILY_RUN(CURRENT_DATE(), 30);")
    print("═" * 60)


if __name__ == '__main__':
    main()
