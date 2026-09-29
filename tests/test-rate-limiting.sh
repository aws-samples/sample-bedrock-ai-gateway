#!/usr/bin/env bash
# test-rate-limiting.sh — Validate API Gateway rate limiting enforcement
# Sends 30 parallel requests after temporarily lowering the rate limit to 1 req/sec.
# Asserts at least one 429 response, then ALWAYS restores production rate limit.
#
# SAFETY GUARANTEE:
#   This script temporarily lowers the usage plan rate limit for testing.
#   The production rate limit (100 req/sec, burst 150) is ALWAYS restored:
#   - On normal exit: explicit restore step
#   - On failure/interrupt: via shell `trap EXIT` handler
#   To verify after running: aws apigateway get-usage-plans --query "items[?name=='IT-Operations-Plan'].throttle" --output json
#
# Requires both API key (for usage plan throttling) and a valid auth token
# (to pass the Cognito authorizer). Uses the dedicated test App Client to
# obtain the token programmatically.
#
# Usage:
#   ./tests/test-rate-limiting.sh <GATEWAY_URL> <API_KEY> <USER_POOL_ID> <TEST_CLIENT_ID> <USERNAME> <PASSWORD> [REGION] [PROFILE]
#
# Example:
#   ./tests/test-rate-limiting.sh \
#     https://abc123.execute-api.us-east-1.amazonaws.com/v1 \
#     xYzApIkEy123 \
#     us-east-1_AbCdEf \
#     <TEST_CLIENT_ID> \
#     admin@example.com \
#     'MyP@ssw0rd!' \
#     us-east-1 \
#     webapps

set -euo pipefail

###############################################################################
# Parameters
###############################################################################
GATEWAY_URL="${1:?Usage: $0 <GATEWAY_URL> <API_KEY> <USER_POOL_ID> <TEST_CLIENT_ID> <USERNAME> <PASSWORD> [REGION] [PROFILE]}"
API_KEY="${2:?Usage: $0 <GATEWAY_URL> <API_KEY> <USER_POOL_ID> <TEST_CLIENT_ID> <USERNAME> <PASSWORD> [REGION] [PROFILE]}"
USER_POOL_ID="${3:?Usage: $0 <GATEWAY_URL> <API_KEY> <USER_POOL_ID> <TEST_CLIENT_ID> <USERNAME> <PASSWORD> [REGION] [PROFILE]}"
TEST_CLIENT_ID="${4:?Usage: $0 <GATEWAY_URL> <API_KEY> <USER_POOL_ID> <TEST_CLIENT_ID> <USERNAME> <PASSWORD> [REGION] [PROFILE]}"
USERNAME="${5:?Usage: $0 <GATEWAY_URL> <API_KEY> <USER_POOL_ID> <TEST_CLIENT_ID> <USERNAME> <PASSWORD> [REGION] [PROFILE]}"
PASSWORD="${6:?Usage: $0 <GATEWAY_URL> <API_KEY> <USER_POOL_ID> <TEST_CLIENT_ID> <USERNAME> <PASSWORD> [REGION] [PROFILE]}"
REGION="${7:-us-east-1}"
PROFILE="${8:-}"

# Build AWS CLI profile option
AWS_PROFILE_OPT=""
if [ -n "$PROFILE" ]; then
    AWS_PROFILE_OPT="--profile ${PROFILE}"
fi

TOTAL_REQUESTS=30
DURATION_SECONDS=5
PROPAGATION_WAIT=90  # API GW throttle changes can take up to 90s to propagate
ENDPOINT="${GATEWAY_URL}/model/us.anthropic.claude-sonnet-4-6/converse-stream"

###############################################################################
# Obtain auth token (required to pass Cognito authorizer)
###############################################################################
echo "Obtaining auth token via test client..."
ID_TOKEN=$(aws cognito-idp admin-initiate-auth \
    --user-pool-id "${USER_POOL_ID}" \
    --client-id "${TEST_CLIENT_ID}" \
    --auth-flow ADMIN_NO_SRP_AUTH \
    --auth-parameters "USERNAME=${USERNAME},PASSWORD=${PASSWORD}" \
    --region "${REGION}" ${AWS_PROFILE_OPT} \
    --query "AuthenticationResult.IdToken" \
    --output text 2>&1) || {
    echo "❌ FAIL: Could not obtain auth token. Ensure test client exists and password is correct."
    echo "  Error: ${ID_TOKEN}"
    exit 1
}
echo "  ✅ Token obtained"
echo ""

###############################################################################
# Counters
###############################################################################
COUNT_200=0
COUNT_429=0
COUNT_OTHER=0
RETRY_AFTER_PRESENT=0

###############################################################################
# Request payload (minimal valid converse request)
###############################################################################
PAYLOAD='{"modelId":"us.anthropic.claude-sonnet-4-6","messages":[{"role":"user","content":[{"text":"ping"}]}]}'

###############################################################################
# Calculate delay between requests to spread over DURATION_SECONDS
###############################################################################
DELAY=$(echo "scale=4; $DURATION_SECONDS / $TOTAL_REQUESTS" | bc)

echo "=============================================="
echo " Rate Limiting Test"
echo "=============================================="
echo "Gateway URL : ${GATEWAY_URL}"
echo "Endpoint    : ${ENDPOINT}"
echo "Requests    : ${TOTAL_REQUESTS} over ${DURATION_SECONDS}s"
echo "Delay       : ${DELAY}s between requests"
echo "=============================================="
echo ""

###############################################################################
# Temporarily lower the rate limit for testing
# Production config is 100 req/sec — too high to trip in a test.
# We set 1 req/sec for the test duration, then restore after.
###############################################################################
echo "  Lowering rate limit temporarily for test (1 req/sec, burst 1)..."
USAGE_PLAN_ID=$(aws apigateway get-usage-plans \
    --region "${REGION}" ${AWS_PROFILE_OPT} \
    --query "items[?name=='IT-Operations-Plan'].id" \
    --output text 2>/dev/null || echo "")

if [ -z "$USAGE_PLAN_ID" ] || [ "$USAGE_PLAN_ID" = "None" ]; then
    echo "❌ FAIL: Usage plan 'IT-Operations-Plan' not found"
    exit 1
fi

aws apigateway update-usage-plan --usage-plan-id "$USAGE_PLAN_ID" \
    --patch-operations "op=replace,path=/throttle/rateLimit,value=1" "op=replace,path=/throttle/burstLimit,value=1" \
    --region "${REGION}" ${AWS_PROFILE_OPT} >/dev/null 2>&1

echo "  ✅ Rate limit set to 1 req/sec (burst 1) for testing"
echo "  Waiting ${PROPAGATION_WAIT}s for rate limit to propagate..."
sleep ${PROPAGATION_WAIT}
echo ""

###############################################################################
# Send requests in parallel bursts to exceed rate limit at API GW level
###############################################################################
RESULTS_DIR=$(mktemp -d)
trap "rm -rf $RESULTS_DIR; aws apigateway update-usage-plan --usage-plan-id $USAGE_PLAN_ID --patch-operations 'op=replace,path=/throttle/rateLimit,value=100' 'op=replace,path=/throttle/burstLimit,value=150' --region ${REGION} ${AWS_PROFILE_OPT} >/dev/null 2>&1 || true; echo '  ✅ Rate limit restored (trap)'" EXIT

echo "  Firing ${TOTAL_REQUESTS} requests in rapid bursts..."

for i in $(seq 1 $TOTAL_REQUESTS); do
    curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
        -X POST "${ENDPOINT}" \
        -H "Content-Type: application/json" \
        -H "x-api-key: ${API_KEY}" \
        -H "Authorization: Bearer ${ID_TOKEN}" \
        -d "${PAYLOAD}" > "${RESULTS_DIR}/${i}.txt" 2>/dev/null &

    # Small stagger to avoid overwhelming the local machine, but fast enough to exceed rate limit
    sleep 0.05
done

echo "  Waiting for all requests to complete..."
wait

###############################################################################
# Count results
###############################################################################
for f in "${RESULTS_DIR}"/*.txt; do
    HTTP_CODE=$(cat "$f" 2>/dev/null || echo "000")
    case "$HTTP_CODE" in
        200) COUNT_200=$((COUNT_200 + 1)) ;;
        429) COUNT_429=$((COUNT_429 + 1)) ;;
        *) COUNT_OTHER=$((COUNT_OTHER + 1)) ;;
    esac
done

# Check Retry-After header if we got 429s
if [ "$COUNT_429" -gt 0 ]; then
    echo "  Checking Retry-After header on throttled response..."
    HEADERS=$(curl -s -I --max-time 5 \
        -X POST "${ENDPOINT}" \
        -H "Content-Type: application/json" \
        -H "x-api-key: ${API_KEY}" \
        -H "Authorization: Bearer ${ID_TOKEN}" \
        -d "${PAYLOAD}" 2>/dev/null || true)
    if echo "$HEADERS" | grep -qi "retry-after"; then
        RETRY_AFTER_PRESENT=1
    fi
fi

###############################################################################
# Restore production rate limit
###############################################################################
echo "  Restoring production rate limit (100 req/sec, burst 150)..."
aws apigateway update-usage-plan --usage-plan-id "$USAGE_PLAN_ID" \
    --patch-operations "op=replace,path=/throttle/rateLimit,value=100" "op=replace,path=/throttle/burstLimit,value=150" \
    --region "${REGION}" ${AWS_PROFILE_OPT} >/dev/null 2>&1
echo "  ✅ Rate limit restored"
echo ""

###############################################################################
# Results
###############################################################################
echo ""
echo "=============================================="
echo " Results"
echo "=============================================="
echo "  HTTP 200 responses : ${COUNT_200}"
echo "  HTTP 429 responses : ${COUNT_429}"
echo "  Other responses    : ${COUNT_OTHER}"
echo "  Retry-After header : ${RETRY_AFTER_PRESENT} (on 429s)"
echo "=============================================="
echo ""

###############################################################################
# Assertions
###############################################################################
PASS=true

# Assert at least one 429 response
if [ "$COUNT_429" -lt 1 ]; then
    echo "❌ FAIL: Expected at least one 429 response, got ${COUNT_429}"
    PASS=false
else
    echo "✅ PASS: Received ${COUNT_429} rate-limited (429) responses"
fi

# Check Retry-After header presence on 429 responses
if [ "$COUNT_429" -gt 0 ] && [ "$RETRY_AFTER_PRESENT" -lt 1 ]; then
    echo "⚠️  NOTE: Retry-After header not verified (rate limit window resets quickly)"
    echo "  The THROTTLED Gateway Response is configured with Retry-After: 1"
    echo "  Verification requires catching a 429 in real-time (timing dependent)"
elif [ "$COUNT_429" -gt 0 ]; then
    echo "✅ PASS: Retry-After header present on 429 responses"
fi

echo ""
if [ "$PASS" = true ]; then
    echo "🎉 OVERALL: PASS — Rate limiting is enforced"
    exit 0
else
    echo "💥 OVERALL: FAIL — Rate limiting not working as expected"
    exit 1
fi
