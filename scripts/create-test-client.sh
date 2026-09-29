#!/usr/bin/env bash
# create-test-client.sh — Create a dedicated Cognito App Client for test automation
#
# This creates a SEPARATE App Client from the production one. The production client
# uses OAuth2/PKCE authorization code flow only (no password-based auth). This test
# client enables ADMIN_NO_SRP_AUTH so automated test scripts can obtain tokens
# programmatically without browser-based OAuth redirects.
#
# Security: The production client remains hardened. The Lambda Authorizer validates
# tokens from the same User Pool regardless of which App Client issued them.
#
# Usage:
#   ./scripts/create-test-client.sh <USER_POOL_ID> [REGION] [PROFILE]
#
# Example:
#   ./scripts/create-test-client.sh us-east-1_s7TKOugWZ us-east-1 webapps

set -euo pipefail

###############################################################################
# Parameters
###############################################################################
USER_POOL_ID="${1:?Usage: $0 <USER_POOL_ID> [REGION] [PROFILE] [CLIENT_NAME]}"
REGION="${2:-us-east-1}"
PROFILE="${3:-}"
# Accept an explicit client name so deploy.sh can pass ${COMPANY_NAME}-${STAGE}-test-client.
# Falls back to a generic name when called standalone.
CLIENT_NAME="${4:-ai-gateway-test-client}"

# Build AWS CLI options
AWS_OPTS="--region ${REGION}"
if [ -n "$PROFILE" ]; then
    AWS_OPTS="${AWS_OPTS} --profile ${PROFILE}"
fi

###############################################################################
# Check if test client already exists
###############################################################################
echo "🔍 Checking for existing test client '${CLIENT_NAME}'..."

EXISTING_CLIENTS=$(aws cognito-idp list-user-pool-clients \
    --user-pool-id "${USER_POOL_ID}" \
    --max-results 60 \
    ${AWS_OPTS} \
    --query "UserPoolClients[?ClientName=='${CLIENT_NAME}'].ClientId" \
    --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_CLIENTS" ] && [ "$EXISTING_CLIENTS" != "None" ]; then
    echo "✅ Test client already exists: ${EXISTING_CLIENTS}"
    echo ""
    echo "TEST_CLIENT_ID=${EXISTING_CLIENTS}"
    exit 0
fi

###############################################################################
# Create the test App Client
###############################################################################
echo "🔧 Creating test App Client '${CLIENT_NAME}' in User Pool ${USER_POOL_ID}..."

RESULT=$(aws cognito-idp create-user-pool-client \
    --user-pool-id "${USER_POOL_ID}" \
    --client-name "${CLIENT_NAME}" \
    --explicit-auth-flows ALLOW_ADMIN_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH \
    --prevent-user-existence-errors ENABLED \
    --token-validity-units '{"AccessToken":"hours","IdToken":"hours","RefreshToken":"days"}' \
    --access-token-validity 1 \
    --id-token-validity 1 \
    --refresh-token-validity 30 \
    ${AWS_OPTS} \
    --output json 2>&1)

TEST_CLIENT_ID=$(echo "$RESULT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data['UserPoolClient']['ClientId'])
" 2>/dev/null || echo "")

if [ -z "$TEST_CLIENT_ID" ]; then
    echo "❌ Failed to create test client"
    echo "  Error: ${RESULT}"
    exit 1
fi

echo "✅ Test client created successfully"
echo ""
echo "=============================================="
echo " Test Client Details"
echo "=============================================="
echo "  Client Name : ${CLIENT_NAME}"
echo "  Client ID   : ${TEST_CLIENT_ID}"
echo "  User Pool   : ${USER_POOL_ID}"
echo "  Auth Flows  : ADMIN_USER_PASSWORD_AUTH, REFRESH_TOKEN_AUTH"
echo "  OAuth Flows : NONE (test automation only)"
echo "  Secret      : NONE (public test client)"
echo "=============================================="
echo ""
echo "Usage in test scripts:"
echo "  ./tests/test-auth.sh <GATEWAY_URL> ${USER_POOL_ID} ${TEST_CLIENT_ID} <USERNAME> <PASSWORD> ${REGION}"
echo ""
echo "TEST_CLIENT_ID=${TEST_CLIENT_ID}"
