#!/bin/bash
set -euo pipefail
#
# ============================================================================
# Western Union CDO Demo — One-Shot Deployment
# ============================================================================
#
# Generates WU synthetic data, deploys the full DCA stack, and intentionally
# breaks contracts to demonstrate the quality automation flow.
#
# This demo answers CDO Surekha Durvasula's two questions:
#   A) Pipeline automation from prompts (Cortex Code + SDLC)
#   B) Semantic schema as quality contract (Semantic Views + DMFs + AI remediation)
#
# Prerequisites:
#   - Core DCA demo deployed (scripts 01-10)
#   - Python 3.8+ with faker
#   - snow CLI (Snowflake CLI) installed
#   - A valid Snowflake connection configured
#
# Usage:
#   ./deploy.sh --connection default              # Full deployment
#   ./deploy.sh --connection default --quick       # Quick mode (10% data)
#   ./deploy.sh --connection default --data-only   # Only generate and load data
#   ./deploy.sh --connection default --sql-only    # Only run SQL scripts
#
# ============================================================================

# ---------------------------------------------------------------------------
# Directory layout
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TOOLS_DIR="${SCRIPT_DIR}/tools"
SQL_DIR="${SCRIPT_DIR}/sql"
DATA_DIR="${SCRIPT_DIR}/data"

# ---------------------------------------------------------------------------
# Defaults (overridden by CLI flags)
# ---------------------------------------------------------------------------
CONNECTION=""
QUICK=false
SCALE="1.0"
DATA_ONLY=false
SQL_ONLY=false

# ---------------------------------------------------------------------------
# Colours / formatting helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Colour

# ============================================================================
# FUNCTIONS
# ============================================================================

print_banner() {
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  WESTERN UNION CDO DEMO — ONE-SHOT DEPLOYMENT              ║"
    echo "║  Payments · KYC · Compliance · Quality Contracts            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo "  Started : $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "  Conn    : ${CONNECTION}"
    echo "  Quick   : ${QUICK}  (scale=${SCALE})"
    echo "  Flags   : data-only=${DATA_ONLY} sql-only=${SQL_ONLY}"
    echo ""
}

usage() {
    cat <<EOF
Usage: $(basename "$0") --connection <NAME> [OPTIONS]

Required:
  --connection NAME       Snowflake CLI connection name (e.g. default)

Options:
  --quick                 Generate ~10% data for fast testing
  --scale FLOAT           Data scale factor (default: 1.0, --quick sets 0.1)
  --data-only             Run only data generation + upload + load
  --sql-only              Run only SQL scripts (assumes data already loaded)
  -h, --help              Show this help message

Examples:
  ./deploy.sh --connection default
  ./deploy.sh --connection default --quick
  ./deploy.sh --connection default --data-only --quick
  ./deploy.sh --connection default --sql-only
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --connection)   CONNECTION="$2"; shift 2 ;;
            --quick)        QUICK=true; SCALE="0.1"; shift ;;
            --scale)        SCALE="$2"; shift 2 ;;
            --data-only)    DATA_ONLY=true; shift ;;
            --sql-only)     SQL_ONLY=true; shift ;;
            -h|--help)      usage ;;
            *)
                echo -e "${RED}[ERROR] Unknown option: $1${NC}" >&2
                echo "Run with --help for usage." >&2
                exit 1
                ;;
        esac
    done

    if [ -z "${CONNECTION}" ]; then
        echo -e "${RED}[ERROR] --connection is required.${NC}" >&2
        echo "Run with --help for usage." >&2
        exit 1
    fi

    if [ "${DATA_ONLY}" = "true" ] && [ "${SQL_ONLY}" = "true" ]; then
        echo -e "${RED}[ERROR] --data-only and --sql-only are mutually exclusive.${NC}" >&2
        exit 1
    fi
}

check_prerequisites() {
    echo -e "${BOLD}Checking prerequisites...${NC}"
    local ok=true

    # Python 3
    if command -v python3 &>/dev/null; then
        echo -e "  ${GREEN}[OK]${NC} python3  $(python3 --version 2>&1)"
    else
        echo -e "  ${RED}[MISSING]${NC} python3"; ok=false
    fi

    # faker
    if python3 -c "import faker" 2>/dev/null; then
        echo -e "  ${GREEN}[OK]${NC} faker    $(python3 -c 'import faker; print(faker.__version__)')"
    else
        echo -e "  ${RED}[MISSING]${NC} faker (pip install faker)"; ok=false
    fi

    # snow CLI
    if command -v snow &>/dev/null; then
        echo -e "  ${GREEN}[OK]${NC} snow CLI $(snow --version 2>&1 | head -1)"
    else
        echo -e "  ${RED}[MISSING]${NC} snow CLI (https://docs.snowflake.com/en/developer-guide/snowflake-cli)"; ok=false
    fi

    echo ""
    if [ "${ok}" = "false" ]; then
        echo -e "${RED}[FATAL] Missing prerequisites. Install them and retry.${NC}"
        exit 1
    fi
}

run_sql_file() {
    local file_path="$1"
    local description="$2"

    if [ ! -f "${file_path}" ]; then
        echo -e "  ${RED}[ERROR] SQL file not found: ${file_path}${NC}"
        return 1
    fi

    echo -e "  ${CYAN}[SQL]${NC} Running: ${description}..."
    if snow sql --connection "${CONNECTION}" --filename "${file_path}"; then
        echo -e "  ${GREEN}[OK]${NC}  ${description} complete"
    else
        echo -e "  ${RED}[FAIL]${NC} ${description} — see error above"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Phase 1 — Data Generation
# ---------------------------------------------------------------------------
phase_1_generate_data() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}PHASE 1: DATA GENERATION${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    mkdir -p "${DATA_DIR}"

    QUICK_FLAG=""
    if [ "${QUICK}" = "true" ]; then QUICK_FLAG="--quick"; fi

    echo "  Generating Western Union payment, KYC, and compliance data..."
    python3 "${TOOLS_DIR}/generate_wu_data.py" --output "${DATA_DIR}" --scale "${SCALE}" ${QUICK_FLAG}

    echo ""
    echo -e "  ${GREEN}[OK]${NC} Data generation complete. Files in ${DATA_DIR}/"
    ls -lh "${DATA_DIR}"/wu_payments/ "${DATA_DIR}"/wu_kyc/ "${DATA_DIR}"/wu_compliance/ 2>/dev/null | tail -30 || true
    echo ""
}

# ---------------------------------------------------------------------------
# Phase 2 — Upload & Load
# ---------------------------------------------------------------------------
phase_2_upload_and_load() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}PHASE 2: DATA UPLOAD & LOAD${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    echo "  Uploading WU Payments data to stage..."
    snow sql --connection "${CONNECTION}" \
        -q "PUT file://${DATA_DIR}/wu_payments/*.csv @RAW_DEV.STAGING.DATA_STAGE/wu_payments/ AUTO_COMPRESS=TRUE OVERWRITE=TRUE;"
    echo -e "  ${GREEN}[OK]${NC} Payments data uploaded"

    echo "  Uploading WU KYC data to stage..."
    snow sql --connection "${CONNECTION}" \
        -q "PUT file://${DATA_DIR}/wu_kyc/*.csv @RAW_DEV.STAGING.DATA_STAGE/wu_kyc/ AUTO_COMPRESS=TRUE OVERWRITE=TRUE;"
    echo -e "  ${GREEN}[OK]${NC} KYC data uploaded"

    echo "  Uploading WU Compliance data to stage..."
    snow sql --connection "${CONNECTION}" \
        -q "PUT file://${DATA_DIR}/wu_compliance/*.csv @RAW_DEV.STAGING.DATA_STAGE/wu_compliance/ AUTO_COMPRESS=TRUE OVERWRITE=TRUE;"
    echo -e "  ${GREEN}[OK]${NC} Compliance data uploaded"

    echo ""
    echo "  Loading data into RAW tables..."
    run_sql_file "${SQL_DIR}/02_wu_load_data.sql" "WU data loader"
    echo -e "  ${GREEN}[OK]${NC} Data load complete"
    echo ""
}

# ---------------------------------------------------------------------------
# Phase 3 — SQL Scripts (Setup + Curated + Semantic + Contracts + Quality)
# ---------------------------------------------------------------------------
phase_3_sql_scripts() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}PHASE 3: SQL SCRIPTS${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    run_sql_file "${SQL_DIR}/01_wu_setup.sql"              "WU schemas and raw tables"
    run_sql_file "${SQL_DIR}/02_wu_load_data.sql"          "WU data loader procedures"
    run_sql_file "${SQL_DIR}/03_wu_curated_layer.sql"      "WU curated Dynamic Tables"
    run_sql_file "${SQL_DIR}/04_wu_semantic_layer.sql"     "WU Semantic Views for Cortex Analyst"
    run_sql_file "${SQL_DIR}/05_wu_contracts.sql"          "WU quality contracts (DMFs)"
    run_sql_file "${SQL_DIR}/06_wu_quality_automation.sql" "WU quality automation (AI remediation)"
    run_sql_file "${SQL_DIR}/07_wu_governance.sql"         "WU governance policies"
    run_sql_file "${SQL_DIR}/08_wu_streamlit.sql"          "WU Streamlit app deployment"

    echo ""
    echo -e "  ${GREEN}[OK]${NC} All SQL scripts complete"
    echo ""
}

# ---------------------------------------------------------------------------
# Phase 4 — Contract Validation (intentionally triggers quality issues)
# ---------------------------------------------------------------------------
phase_4_validate_contracts() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}PHASE 4: CONTRACT VALIDATION${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    echo -e "  ${CYAN}[EXEC]${NC} Running SP_WU_VALIDATE_ALL_CONTRACTS()..."
    echo -e "  ${YELLOW}[NOTE]${NC} Quality issues were intentionally injected — contracts will catch them."
    snow sql --connection "${CONNECTION}" \
        -q "USE ROLE DATA_ADMIN; CALL DCA_DEMO.GOVERNANCE.SP_WU_VALIDATE_ALL_CONTRACTS();"
    echo -e "  ${GREEN}[OK]${NC} Contract validation complete"
    echo ""
}

# ---------------------------------------------------------------------------
# Phase 5 — Validation
# ---------------------------------------------------------------------------
phase_5_validation() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}PHASE 5: VALIDATION${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    echo -e "  ${CYAN}[CHECK]${NC} Running validation queries..."
    snow sql --connection "${CONNECTION}" -q "
USE ROLE DATA_ADMIN;

SELECT '=== RAW TABLE COUNTS ===' AS section;
SELECT 'WU_PAYMENTS.TRANSACTIONS'  AS tbl, COUNT(*) AS rows FROM RAW_DEV.WU_PAYMENTS.TRANSACTIONS
UNION ALL SELECT 'WU_PAYMENTS.CORRIDORS',       COUNT(*) FROM RAW_DEV.WU_PAYMENTS.CORRIDORS
UNION ALL SELECT 'WU_KYC.CUSTOMERS',            COUNT(*) FROM RAW_DEV.WU_KYC.CUSTOMERS
UNION ALL SELECT 'WU_KYC.VERIFICATIONS',        COUNT(*) FROM RAW_DEV.WU_KYC.VERIFICATIONS
UNION ALL SELECT 'WU_COMPLIANCE.SAR_FILINGS',   COUNT(*) FROM RAW_DEV.WU_COMPLIANCE.SAR_FILINGS
UNION ALL SELECT 'WU_COMPLIANCE.SANCTIONS_HITS', COUNT(*) FROM RAW_DEV.WU_COMPLIANCE.SANCTIONS_HITS;

SELECT '=== QUALITY CONTRACT RESULTS ===' AS section;
SELECT contract_name, status, violations_found
  FROM DCA_DEMO.GOVERNANCE.WU_CONTRACT_RESULTS
 ORDER BY violations_found DESC
 LIMIT 10;
"

    echo ""
    echo -e "  ${GREEN}[OK]${NC} Validation complete — review counts above"
    echo ""
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
    local elapsed=$1
    local mins=$((elapsed / 60))
    local secs=$((elapsed % 60))

    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  WESTERN UNION CDO DEMO — DEPLOYMENT COMPLETE              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo "  Duration     : ${mins}m ${secs}s"
    echo "  Connection   : ${CONNECTION}"
    echo "  Data scale   : ${SCALE}"
    echo ""
    echo -e "  ${YELLOW}Quality issues injected: ~1000. Contracts will catch them.${NC}"
    echo ""
    echo "  Streamlit    : Deploy via Snowsight or:"
    echo "    snow streamlit deploy --connection ${CONNECTION}"
    echo ""
    echo "  Next steps   :"
    echo "    1. Run queries in DEMO_SCRIPT.md to verify end-to-end"
    echo "    2. Open Streamlit app -> WU Quality Command Center"
    echo "    3. Review WORKSHOP_1.md through WORKSHOP_4.md for guided sessions"
    echo ""
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    parse_args "$@"
    print_banner
    check_prerequisites

    START_TIME=$(date +%s)

    if [ "${DATA_ONLY}" = "true" ]; then
        phase_1_generate_data
        phase_2_upload_and_load
    elif [ "${SQL_ONLY}" = "true" ]; then
        phase_3_sql_scripts
        phase_4_validate_contracts
    else
        phase_1_generate_data
        phase_2_upload_and_load
        phase_3_sql_scripts
        phase_4_validate_contracts
        phase_5_validation
    fi

    END_TIME=$(date +%s)
    print_summary $((END_TIME - START_TIME))
}

main "$@"
