#!/usr/bin/env bash
# run-all-tests.sh — Run every test in tests/ against a deployed POC.
#
# Runs, in order:
#   1. test-auth.sh          — Authentication enforcement (401/200, API key, access logs)
#   2. test-rate-limiting.sh — Usage plan throttling (429s)
#   3. test-cost-tracking.py — Bedrock invocations + CloudWatch token/cost data
#   4. test-mcp-tools.py     — search_kb / create_ticket Lambda validation (--mode lambda)
#   5. test-agentcore.py     — AgentCore Identity, Memory, Registry, demo agent E2E
#   6. test-bu-cost-attribution.py — per-BU / per-model routing and entitlement rules
#
# All deployment values (gateway URL, user pool ID, API key, etc.) are resolved
# DYNAMICALLY from CloudFormation stack outputs and AWS API calls — no hardcoded
# credentials or resource IDs in this file.
#
# REQUIRED before running:
#   export COGNITO_USERNAME="<your-cognito-email>"
#   export COGNITO_PASSWORD='<your-cognito-password>'
#
#   NOTE: Use COGNITO_USERNAME (not USERNAME) — USERNAME is a reserved macOS
#   system env var (your OS login name) and will silently override any value set.
#
# Optional overrides (auto-resolved if not set):
#   AWS_PROFILE     — AWS named profile (default: uses AWS default credential chain)
#   AWS_REGION      — AWS region (default: us-east-1)
#   STACK_NAME      — CloudFormation stack name (default: anycompany-ai-gateway-poc)
#   GATEWAY_URL     — override auto-resolved API Gateway URL
#   API_KEY         — override auto-resolved IT-Operations API key
#   USER_POOL_ID    — override auto-resolved Cognito User Pool ID
#   TEST_CLIENT_ID  — override auto-resolved test App Client ID
#
# CLI args (take precedence over env vars):
#   --profile <name>   AWS named profile
#   --region  <name>   AWS region
#   --stack   <name>   CloudFormation gateway stack name
#
# Usage:
#   export COGNITO_USERNAME="you@example.com"
#   export COGNITO_PASSWORD='YourPassword'
#   ./tests/run-all-tests.sh

set -uo pipefail  # NOTE: no -e — a single test failure must not abort the run

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

REGION="${AWS_REGION:-us-east-1}"
PROFILE="${AWS_PROFILE:-}"
STACK_NAME="${STACK_NAME:-anycompany-ai-gateway-poc}"

# Accept --profile, --region, --stack as CLI args (env vars still work as fallback)
while [[ $# -gt 0 ]]; do
  case $1 in
    --profile)      PROFILE="$2";     shift 2 ;;
    --region)       REGION="$2";      shift 2 ;;
    --stack)        STACK_NAME="$2";  shift 2 ;;
    *) break ;;  # remaining args not consumed here
  esac
done

STAGE="${STAGE:-$(echo "$STACK_NAME" | sed "s/.*-ai-gateway-//")}"
DASHBOARD_NAME="${STACK_NAME}"  # dashboard follows the same naming as the gateway stack

AWS_OPTS="--region $REGION"
if [ -n "$PROFILE" ]; then
    AWS_OPTS="$AWS_OPTS --profile $PROFILE"
fi

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   AI Gateway POC — Run All Tests                             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo "  Region  : $REGION"
echo "  Profile : $PROFILE"
echo "  Stack   : $STACK_NAME"
echo ""

###############################################################################
# Validate required credentials up front
###############################################################################
if [ -z "${COGNITO_USERNAME:-}" ] || [ -z "${COGNITO_PASSWORD:-}" ]; then
    echo "❌ ERROR: COGNITO_USERNAME and COGNITO_PASSWORD must be set"
    echo ""
    echo "   export COGNITO_USERNAME=\"you@example.com\""
    echo "   export COGNITO_PASSWORD='YourPassword'"
    echo "   ./tests/run-all-tests.sh"
    echo ""
    echo "   Credentials are in .env.md (gitignored) at the repo root."
    exit 1
fi

###############################################################################
# Pre-flight checks — catch common post-deploy issues before wasting test time
###############################################################################
echo "Running pre-flight checks..."
PREFLIGHT_WARNINGS=()

# 1. Check the Cognito user has a confirmed (non-temp) password.
#    Tests use ADMIN_NO_SRP_AUTH which requires CONFIRMED status.
#    FORCE_CHANGE_PASSWORD means the user still has TempPass@2026! set.
COGNITO_USER_STATUS=""
if POOL_ID=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" $AWS_OPTS \
    --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" \
    --output text 2>/dev/null); then
  COGNITO_USER_STATUS=$(aws cognito-idp admin-get-user \
    --user-pool-id "$POOL_ID" \
    --username "$COGNITO_USERNAME" \
    --query 'UserStatus' --output text $AWS_OPTS 2>/dev/null || echo "")
fi

if [ "$COGNITO_USER_STATUS" = "FORCE_CHANGE_PASSWORD" ]; then
    echo ""
    echo "❌ ERROR: Cognito user '${COGNITO_USERNAME}' still has a temporary password."
    echo "   Tests require a permanent password (CONFIRMED status)."
    echo ""
    echo "   Fix: Open the Cognito Login URL in your browser and set a permanent password,"
    echo "   or use the AWS CLI:"
    echo "     aws cognito-idp admin-set-user-password \\"
    echo "       --user-pool-id ${POOL_ID} --username ${COGNITO_USERNAME} \\"
    echo "       --password '<PASSWORD>' --permanent --region ${REGION}"
    echo ""
    exit 1
fi

# 2. Check the search_kb Lambda has a real Knowledge Base ID configured.
#    If Phase 2 hasn't been run, search_kb returns an error and MCP tests fail.
#    Derive the Lambda name from STACK_NAME: replace -ai-gateway- with -mcp-tools-
MCP_STACK_NAME="$(echo "$STACK_NAME" | sed 's/-ai-gateway-/-mcp-tools-/')"
SEARCH_KB_LAMBDA="${MCP_STACK_NAME}-search-kb"
KB_ID_CONFIGURED=$(aws lambda get-function-configuration \
    --function-name "$SEARCH_KB_LAMBDA" \
    --query 'Environment.Variables.KNOWLEDGE_BASE_ID' \
    --output text $AWS_OPTS 2>/dev/null || echo "")

if [ -z "$KB_ID_CONFIGURED" ] || [ "$KB_ID_CONFIGURED" = "None" ] || \
   [ "$KB_ID_CONFIGURED" = "PENDING_PHASE2" ]; then
    PREFLIGHT_WARNINGS+=("search_kb Lambda has no Knowledge Base ID — MCP tool tests will FAIL. Run: bash deploy-phase2.sh --region ${REGION}")
fi

# 3. Check the Bedrock invocation log group exists.
#    Derive log group name from STACK_NAME: replace -ai-gateway- with -
#    e.g. anycompany-ai-gateway-poc → /aws/bedrock/anycompany-poc-invocations
LOG_GROUP_PREFIX="/aws/bedrock/$(echo "$STACK_NAME" | sed 's/-ai-gateway-/-/')-invocations"
LOG_GROUP_EXISTS=$(aws logs describe-log-groups \
    --log-group-name-prefix "$LOG_GROUP_PREFIX" \
    $AWS_OPTS \
    --query "logGroups[0].logGroupName" --output text 2>/dev/null || echo "")

if [ -z "$LOG_GROUP_EXISTS" ] || [ "$LOG_GROUP_EXISTS" = "None" ]; then
    PREFLIGHT_WARNINGS+=("Bedrock invocation log group missing — cost tracking test will FAIL. Run: python3 scripts/enable-logging.py --region ${REGION}")
fi

# Print warnings (non-fatal — tests still run so you see all failures at once)
if [ ${#PREFLIGHT_WARNINGS[@]} -gt 0 ]; then
    echo ""
    echo "  ⚠️  Pre-flight warnings (tests may fail):"
    for w in "${PREFLIGHT_WARNINGS[@]}"; do
        echo "     • $w"
    done
    echo ""
else
    echo "  ✅ Pre-flight checks passed"
fi
echo ""

###############################################################################
# Resolve deployment values dynamically
###############################################################################
echo "Resolving deployment values from CloudFormation and AWS APIs..."

# Gateway URL and User Pool ID — from CloudFormation stack outputs
if [ -z "${GATEWAY_URL:-}" ]; then
    GATEWAY_URL=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" $AWS_OPTS \
        --query "Stacks[0].Outputs[?OutputKey=='GatewayUrl'].OutputValue" \
        --output text 2>/dev/null || echo "")
fi

if [ -z "${USER_POOL_ID:-}" ]; then
    USER_POOL_ID=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" $AWS_OPTS \
        --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" \
        --output text 2>/dev/null || echo "")
fi

# API key — from the IT-Operations usage plan key
if [ -z "${API_KEY:-}" ]; then
    API_KEY=$(aws apigateway get-api-keys \
        --include-values $AWS_OPTS \
        --query "items[?name=='IT-Operations-key'].value | [0]" \
        --output text 2>/dev/null || echo "")
fi

# Test App Client — find the dedicated test client (not the production OAuth2/PKCE client)
if [ -z "${TEST_CLIENT_ID:-}" ] && [ -n "$USER_POOL_ID" ]; then
    TEST_CLIENT_ID=$(aws cognito-idp list-user-pool-clients \
        --user-pool-id "$USER_POOL_ID" $AWS_OPTS \
        --query "UserPoolClients[?contains(ClientName, 'test')].ClientId | [0]" \
        --output text 2>/dev/null || echo "")
fi

# Validate all resolved values
MISSING=()
[ -z "${GATEWAY_URL:-}"    ] && MISSING+=("GATEWAY_URL (check CloudFormation stack '$STACK_NAME')")
[ -z "${USER_POOL_ID:-}"   ] && MISSING+=("USER_POOL_ID (check CloudFormation stack '$STACK_NAME')")
[ -z "${API_KEY:-}"        ] && MISSING+=("API_KEY (check API Gateway usage plan 'IT-Operations-Plan')")
[ -z "${TEST_CLIENT_ID:-}" ] && MISSING+=("TEST_CLIENT_ID (run: ./scripts/create-test-client.sh)")

if [ "${#MISSING[@]}" -gt 0 ]; then
    echo ""
    echo "❌ ERROR: could not resolve required deployment values:"
    for m in "${MISSING[@]}"; do
        echo "   - $m"
    done
    echo ""
    echo "   Ensure the POC is fully deployed (deploy.sh completed) and retry."
    exit 1
fi

echo "  ✅ GATEWAY_URL  : $GATEWAY_URL"
echo "  ✅ USER_POOL_ID : $USER_POOL_ID"
echo "  ✅ API_KEY      : ${API_KEY:0:8}... (truncated)"
echo "  ✅ TEST_CLIENT  : $TEST_CLIENT_ID"
echo "  ✅ COGNITO_USER : $COGNITO_USERNAME"
echo ""

if [ -n "$PROFILE" ]; then
    export AWS_PROFILE="$PROFILE"
fi
export AWS_REGION="$REGION"

###############################################################################
# Test runner — tracks pass/fail without aborting on a single failure
###############################################################################
declare -a RESULT_NAMES=()
declare -a RESULT_STATUS=()

run_test() {
    local name="$1"
    shift
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "▶ $name"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if "$@"; then
        RESULT_NAMES+=("$name"); RESULT_STATUS+=("PASS")
    else
        RESULT_NAMES+=("$name"); RESULT_STATUS+=("FAIL")
    fi
}

###############################################################################
# 1. Authentication
###############################################################################
run_test "Authentication (test-auth.sh)" \
    bash "$SCRIPT_DIR/test-auth.sh" \
        "$GATEWAY_URL" "$USER_POOL_ID" "$TEST_CLIENT_ID" \
        "$COGNITO_USERNAME" "$COGNITO_PASSWORD" \
        "$REGION" "$PROFILE" "$API_KEY"

###############################################################################
# 2. Rate limiting
###############################################################################
run_test "Rate Limiting (test-rate-limiting.sh)" \
    bash "$SCRIPT_DIR/test-rate-limiting.sh" \
        "$GATEWAY_URL" "$API_KEY" "$USER_POOL_ID" "$TEST_CLIENT_ID" \
        "$COGNITO_USERNAME" "$COGNITO_PASSWORD" \
        "$REGION" "$PROFILE"

###############################################################################
# 3. Cost tracking (Architecture team)
###############################################################################
run_test "Cost Tracking — Architecture (test-cost-tracking.py)" \
    python3 "$SCRIPT_DIR/test-cost-tracking.py" \
        --gateway-url "$GATEWAY_URL" --api-key "$API_KEY" \
        --user-pool-id "$USER_POOL_ID" --test-client-id "$TEST_CLIENT_ID" \
        --username "$COGNITO_USERNAME" --password "$COGNITO_PASSWORD" \
        --region "$REGION"

###############################################################################
# 3b. Cost tracking (IT-Operations team) — drives traffic through the
#     IT-Operations AIP so the "Token Usage by BU" and "Cost by BU" dashboard
#     widgets show data for both business units, not just Architecture.
#     Requires demo-itops@example.com to have a permanent password set.
###############################################################################
ITOPS_USERNAME="${ITOPS_USERNAME:-demo-itops@example.com}"
ITOPS_PASSWORD="${ITOPS_PASSWORD:-$COGNITO_PASSWORD}"

# Verify the IT-Operations user has a confirmed password before running.
ITOPS_STATUS=$(aws cognito-idp admin-get-user \
    --user-pool-id "$USER_POOL_ID" \
    --username "$ITOPS_USERNAME" \
    --query 'UserStatus' --output text $AWS_OPTS 2>/dev/null || echo "NOT_FOUND")

if [ "$ITOPS_STATUS" = "CONFIRMED" ]; then
    run_test "Cost Tracking — IT-Operations (test-cost-tracking.py)" \
        python3 "$SCRIPT_DIR/test-cost-tracking.py" \
            --gateway-url "$GATEWAY_URL" --api-key "$API_KEY" \
            --user-pool-id "$USER_POOL_ID" --test-client-id "$TEST_CLIENT_ID" \
            --username "$ITOPS_USERNAME" --password "$ITOPS_PASSWORD" \
            --region "$REGION"
else
    echo ""
    echo "  ⏭️  Skipping IT-Operations cost tracking (user status: ${ITOPS_STATUS})"
    echo "       Set permanent password: aws cognito-idp admin-set-user-password \\"
    echo "         --user-pool-id $USER_POOL_ID --username $ITOPS_USERNAME \\"
    echo "         --password '<PASSWORD>' --permanent --region $REGION"
fi

###############################################################################
# 4. MCP tools (Lambda mode — no AgentCore Gateway CLI dependency)
###############################################################################
run_test "MCP Tools (test-mcp-tools.py)" \
    python3 "$SCRIPT_DIR/test-mcp-tools.py" --mode lambda --region "$REGION" \
        --search-kb-name "${MCP_STACK_NAME}-search-kb" \
        --create-ticket-name "${MCP_STACK_NAME}-create-ticket"

###############################################################################
# 5. AgentCore primitives
###############################################################################
PROFILE_OPT=()
[ -n "$PROFILE" ] && PROFILE_OPT=(--profile "$PROFILE")

run_test "AgentCore Primitives (test-agentcore.py)" \
    python3 "$ROOT_DIR/tests/test-agentcore.py" --region "$REGION" "${PROFILE_OPT[@]}"

###############################################################################
# 6. Business-unit cost attribution and model entitlement
###############################################################################
run_test "BU Cost Attribution (test-bu-cost-attribution.py)" \
    python3 "$ROOT_DIR/tests/test-bu-cost-attribution.py" \
        --live --region "$REGION" "${PROFILE_OPT[@]}"

###############################################################################
# Summary
###############################################################################
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   Summary                                                     ║"
echo "╚══════════════════════════════════════════════════════════════╝"

OVERALL_PASS=true
for i in "${!RESULT_NAMES[@]}"; do
    if [ "${RESULT_STATUS[$i]}" = "PASS" ]; then
        echo "  ✅ PASS  ${RESULT_NAMES[$i]}"
    else
        echo "  ❌ FAIL  ${RESULT_NAMES[$i]}"
        OVERALL_PASS=false
    fi
done

echo ""
echo "  Dashboard : CloudWatch -> Dashboards -> ${DASHBOARD_NAME}"
echo "  (allow ~5 minutes for CloudWatch metrics/logs to propagate)"
echo ""

if [ "$OVERALL_PASS" = true ]; then
    echo "🎉 OVERALL: ALL TESTS PASSED"
    exit 0
else
    echo "💥 OVERALL: ONE OR MORE TESTS FAILED — see output above"
    exit 1
fi
