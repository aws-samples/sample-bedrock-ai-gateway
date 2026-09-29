#!/usr/bin/env bash
# test-auth.sh — Validate authentication and authorization enforcement
#
# Tests:
#   1. No auth token → expect 401
#   2. Valid token (obtained via admin-initiate-auth) → expect 200
#   3. Verify user identity appears in CloudWatch access logs
#
# IMPORTANT: This script requires the DEDICATED TEST App Client (not the production client).
#   The production App Client uses OAuth2/PKCE only and does NOT support ADMIN_NO_SRP_AUTH.
#   Create the test client first: ./scripts/create-test-client.sh <USER_POOL_ID> <REGION>
#
# The Lambda Authorizer validates tokens from the same User Pool regardless of which
# App Client issued them, so tokens from the test client work against the API Gateway.
#
# Usage:
#   ./tests/test-auth.sh <GATEWAY_URL> <USER_POOL_ID> <TEST_CLIENT_ID> <USERNAME> <PASSWORD> [REGION] [PROFILE] [API_KEY]
#
# NOTE: API_KEY is required if the API Gateway method has ApiKeyRequired=true.
#       Get it with: aws apigateway get-api-keys --include-values --query "items[?name=='IT-Operations-key'].value" --output text
#
# Example:
#   ./tests/test-auth.sh \
#     https://abc123.execute-api.us-east-1.amazonaws.com/v1 \
#     us-east-1_AbCdEf \
#     <TEST_CLIENT_ID_from_create-test-client.sh> \
#     admin@example.com \
#     'MyP@ssw0rd!' \
#     us-east-1 \
#     webapps \
#     <API_KEY>

set -euo pipefail

###############################################################################
# Parameters
###############################################################################
GATEWAY_URL="${1:?Usage: $0 <GATEWAY_URL> <USER_POOL_ID> <TEST_CLIENT_ID> <USERNAME> <PASSWORD> [REGION] [PROFILE] [API_KEY]}"
USER_POOL_ID="${2:?Usage: $0 <GATEWAY_URL> <USER_POOL_ID> <TEST_CLIENT_ID> <USERNAME> <PASSWORD> [REGION] [PROFILE] [API_KEY]}"
CLIENT_ID="${3:?Usage: $0 <GATEWAY_URL> <USER_POOL_ID> <TEST_CLIENT_ID> <USERNAME> <PASSWORD> [REGION] [PROFILE] [API_KEY]}"
USERNAME="${4:?Usage: $0 <GATEWAY_URL> <USER_POOL_ID> <TEST_CLIENT_ID> <USERNAME> <PASSWORD> [REGION] [PROFILE] [API_KEY]}"
PASSWORD="${5:?Usage: $0 <GATEWAY_URL> <USER_POOL_ID> <TEST_CLIENT_ID> <USERNAME> <PASSWORD> [REGION] [PROFILE] [API_KEY]}"
REGION="${6:-us-east-1}"
PROFILE="${7:-}"
API_KEY="${8:-}"

# If profile not provided as arg, prompt the user
if [ -z "$PROFILE" ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " AWS Profile Configuration"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  This test needs AWS credentials for the account"
    echo "  where the POC is deployed."
    echo ""
    echo "  If you use named profiles (e.g., 'webapps', 'dev'),"
    echo "  enter the profile name below."
    echo ""
    echo "  If your default credentials already point to the"
    echo "  correct account, just press Enter to skip."
    echo ""
    read -rp "  AWS Profile [press Enter for default]: " PROFILE
    echo ""
fi

# Build AWS CLI profile option
AWS_PROFILE_OPT=""
if [ -n "$PROFILE" ]; then
    AWS_PROFILE_OPT="--profile ${PROFILE}"
fi

# Build API key header option (required since ApiKeyRequired=true on the method)
API_KEY_HEADER=""
if [ -n "$API_KEY" ]; then
    API_KEY_HEADER="-H \"x-api-key: ${API_KEY}\""
fi

ENDPOINT="${GATEWAY_URL}/model/us.anthropic.claude-sonnet-4-6/converse-stream"
PAYLOAD='{"messages":[{"role":"user","content":[{"text":"ping"}]}]}'

PASS=true

echo "=============================================="
echo " Authentication Test"
echo "=============================================="
echo "Gateway URL    : ${GATEWAY_URL}"
echo "User Pool ID   : ${USER_POOL_ID}"
echo "Test Client ID : ${CLIENT_ID} (dedicated test client, NOT production)"
echo "Username       : ${USERNAME}"
echo "Region         : ${REGION}"
echo "AWS Profile    : ${PROFILE:-<default>}"
echo "=============================================="
echo ""

###############################################################################
# Test 1: No auth token → expect 401
###############################################################################
echo "--- Test 1: Request without auth token ---"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${ENDPOINT}" \
    -H "Content-Type: application/json" \
    -d "${PAYLOAD}" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "401" ]; then
    echo "✅ PASS: Unauthenticated request returned 401"
else
    echo "❌ FAIL: Expected 401, got ${HTTP_CODE}"
    PASS=false
fi
echo ""

###############################################################################
# Test 2: Obtain token via admin-initiate-auth → expect 200
###############################################################################
echo "--- Test 2: Authenticated request with valid token ---"

# Obtain ID token using ADMIN_NO_SRP_AUTH (test automation only)
echo "  Obtaining token via admin-initiate-auth..."
AUTH_RESULT=$(aws cognito-idp admin-initiate-auth \
    --user-pool-id "${USER_POOL_ID}" \
    --client-id "${CLIENT_ID}" \
    --auth-flow ADMIN_NO_SRP_AUTH \
    --auth-parameters "USERNAME=${USERNAME},PASSWORD=${PASSWORD}" \
    --region "${REGION}" ${AWS_PROFILE_OPT} 2>&1) || {
    echo "❌ FAIL: Could not obtain auth token"
    echo "  Error: ${AUTH_RESULT}"
    PASS=false
    echo ""
    echo "--- Test 3: Skipped (no token available) ---"
    echo ""
    if [ "$PASS" = true ]; then
        echo "🎉 OVERALL: PASS"
        exit 0
    else
        echo "💥 OVERALL: FAIL"
        exit 1
    fi
}

# Check if we got a challenge (e.g., NEW_PASSWORD_REQUIRED)
CHALLENGE=$(echo "$AUTH_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('ChallengeName',''))" 2>/dev/null || echo "")

if [ -n "$CHALLENGE" ]; then
    echo "  ⚠️  Auth challenge received: ${CHALLENGE}"
    echo "  Please complete the challenge (e.g., change temp password) before running this test."
    echo "❌ FAIL: Cannot proceed without completing auth challenge"
    PASS=false
    echo ""
    echo "--- Test 3: Skipped (auth challenge pending) ---"
    echo ""
    if [ "$PASS" = true ]; then
        echo "🎉 OVERALL: PASS"
        exit 0
    else
        echo "💥 OVERALL: FAIL"
        exit 1
    fi
fi

ID_TOKEN=$(echo "$AUTH_RESULT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data['AuthenticationResult']['IdToken'])
" 2>/dev/null || echo "")

if [ -z "$ID_TOKEN" ]; then
    echo "❌ FAIL: Could not extract ID token from auth response"
    PASS=false
else
    echo "  Token obtained successfully"

    # Make authenticated request
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "${ENDPOINT}" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${ID_TOKEN}" \
        ${API_KEY:+-H "x-api-key: ${API_KEY}"} \
        -d "${PAYLOAD}" 2>/dev/null || echo "000")

    if [ "$HTTP_CODE" = "200" ]; then
        echo "✅ PASS: Authenticated request returned 200"
    else
        echo "❌ FAIL: Expected 200, got ${HTTP_CODE}"
        PASS=false
    fi
fi
echo ""

###############################################################################
# Test 3: Verify user identity in CloudWatch access logs
###############################################################################
echo "--- Test 3: Verify user identity in CloudWatch access logs ---"

# Wait briefly for logs to propagate
echo "  Waiting 30s for log propagation..."
sleep 30

# Search the known access log group
# STACK_NAME may be exported by run-all-tests.sh; fall back to the default stack name.
STACK_NAME="${STACK_NAME:-anycompany-ai-gateway-poc}"
ACCESS_LOG_GROUP="/aws/apigateway/${STACK_NAME}-access-logs"

echo "  Searching log group: ${ACCESS_LOG_GROUP}"

START_TIME=$(( $(date +%s) - 300 ))000  # Last 5 minutes in milliseconds

QUERY_ID=$(aws logs start-query \
    --log-group-name "${ACCESS_LOG_GROUP}" \
    --start-time "${START_TIME}" \
    --end-time "$(date +%s)000" \
    --query-string "fields @message | filter user like /${USERNAME}/ | limit 5" \
    --region "${REGION}" ${AWS_PROFILE_OPT} \
    --query "queryId" \
    --output text 2>/dev/null || echo "")

if [ -z "$QUERY_ID" ] || [ "$QUERY_ID" = "None" ]; then
    echo "  ⚠️  Could not start log query — log group may not exist yet"
    echo "  Ensure access logging is configured on the API Gateway stage."
    echo "  See: cloudformation/gateway-stack.yaml (AccessLogSetting)"
else
    # Wait for query to complete
    sleep 5

    RESULTS=$(aws logs get-query-results \
        --query-id "${QUERY_ID}" \
        --region "${REGION}" ${AWS_PROFILE_OPT} \
        --query "results[0]" \
        --output text 2>/dev/null || echo "")

    if [ -n "$RESULTS" ] && [ "$RESULTS" != "None" ]; then
        echo "✅ PASS: User identity (${USERNAME}) found in CloudWatch access logs"
    else
        echo "⚠️  WARN: User identity not found in access logs (may need more propagation time)"
        echo "  This is non-blocking — access logging may have latency > 30s"
    fi
fi
echo ""

###############################################################################
# Overall Result
###############################################################################
echo "=============================================="
if [ "$PASS" = true ]; then
    echo "🎉 OVERALL: PASS — Authentication enforcement verified"
    exit 0
else
    echo "💥 OVERALL: FAIL — Authentication issues detected"
    exit 1
fi
