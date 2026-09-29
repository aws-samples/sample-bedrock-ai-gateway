#!/bin/bash
# register-tools.sh — Create an AgentCore Gateway (MCP) with semantic discovery,
# wire it to Cognito for machine-to-machine (M2M) auth, and register the two
# custom Lambda functions (search_kb, create_ticket) as MCP tools.
#
# Usage:
#   ./register-tools.sh <gateway-name> <search-kb-arn> <create-ticket-arn> <user-pool-id>
#
# Region is read from AWS_REGION (falls back to us-east-1).
#
# This script is idempotent: re-running it reuses the existing IAM role,
# Cognito resource server / M2M client, gateway, and targets.
#
# AgentCore control-plane operations use the `aws bedrock-agentcore-control`
# service (present in recent AWS CLI v2 builds). On success it writes connection
# details (gateway URL, M2M client id/secret, token endpoint, tool names) to
# .agentcore-config.json at the repo root. That file is gitignored because it
# contains the M2M client secret.

set -euo pipefail

GATEWAY_NAME="${1:?Usage: $0 <gateway-name> <search-kb-arn> <create-ticket-arn> <user-pool-id>}"
SEARCH_KB_ARN="${2:?Missing search_kb Lambda ARN}"
CREATE_TICKET_ARN="${3:?Missing create_ticket Lambda ARN}"
USER_POOL_ID="${4:?Missing Cognito User Pool ID}"

REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TOOLS_JSON="$ROOT_DIR/config/gateway-tools.json"
OUT_FILE="$ROOT_DIR/.agentcore-config.json"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# Derived resource names — keyed off GATEWAY_NAME so multiple deployments
# with different --company-name / --stage don't collide in the same account.
# GATEWAY_NAME = "<company>-ai-gateway-<stage>", e.g. "anycompany-ai-gateway-poc"
ROLE_NAME="${GATEWAY_NAME}-gateway-role"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
# Resource server ID is the OAuth2 scope namespace in Cognito — kept short and
# fixed so the scope string stays readable. One deployment per account is typical.
RESOURCE_SERVER_ID="ai-gateway"
SCOPE_NAME="invoke"
FULL_SCOPE="${RESOURCE_SERVER_ID}/${SCOPE_NAME}"
M2M_CLIENT_NAME="${GATEWAY_NAME}-agent-m2m"
DISCOVERY_URL="https://cognito-idp.${REGION}.amazonaws.com/${USER_POOL_ID}/.well-known/openid-configuration"

# AgentCore control-plane CLI client.
ACC="aws bedrock-agentcore-control --region $REGION"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   AgentCore Gateway + MCP Tool Registration                  ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo "  Gateway:     $GATEWAY_NAME"
echo "  Region:      $REGION"
echo "  User Pool:   $USER_POOL_ID"
echo "  search_kb:   $SEARCH_KB_ARN"
echo "  create_tkt:  $CREATE_TICKET_ARN"
echo ""

###############################################################################
# Step 1: Gateway service IAM role (assumed by the gateway to invoke targets)
###############################################################################
echo "▶ Step 1: Gateway service IAM role..."

TRUST_POLICY="$(jq -nc \
  --arg acct "$ACCOUNT_ID" \
  '{
    Version: "2012-10-17",
    Statement: [{
      Effect: "Allow",
      Principal: { Service: "bedrock-agentcore.amazonaws.com" },
      Action: "sts:AssumeRole",
      Condition: { StringEquals: { "aws:SourceAccount": $acct } }
    }]
  }')"

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "  ⏭️  Role $ROLE_NAME already exists"
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" \
    --policy-document "$TRUST_POLICY" >/dev/null
else
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --description "AI Gateway - AgentCore Gateway service role" \
    --tags Key=Application,Value=AIGatewayPOC Key=CostCenter,Value=IT-Operations \
    >/dev/null
  echo "  ✅ Created role $ROLE_NAME"
fi

# Inline policy: invoke the two target Lambdas + keep semantic search in sync.
ROLE_POLICY="$(jq -nc \
  --arg skb "$SEARCH_KB_ARN" \
  --arg ctk "$CREATE_TICKET_ARN" \
  --arg gw "arn:aws:bedrock-agentcore:${REGION}:${ACCOUNT_ID}:gateway/*" \
  '{
    Version: "2012-10-17",
    Statement: [
      {
        Sid: "InvokeToolLambdas",
        Effect: "Allow",
        Action: "lambda:InvokeFunction",
        Resource: [$skb, $ctk]
      },
      {
        Sid: "SemanticSearchSync",
        Effect: "Allow",
        Action: "bedrock-agentcore:SynchronizeGatewayTargets",
        Resource: $gw
      }
    ]
  }')"

aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name "gateway-target-access" \
  --policy-document "$ROLE_POLICY" >/dev/null
echo "  ✅ Attached target-access policy"
echo "     Waiting 10s for IAM propagation..."
sleep 10
echo ""

###############################################################################
# Step 2: Cognito resource server + scope (required for M2M client_credentials)
###############################################################################
echo "▶ Step 2: Cognito resource server + scope..."

if aws cognito-idp describe-resource-server \
  --user-pool-id "$USER_POOL_ID" --identifier "$RESOURCE_SERVER_ID" \
  --region "$REGION" >/dev/null 2>&1; then
  echo "  ⏭️  Resource server $RESOURCE_SERVER_ID already exists"
  aws cognito-idp update-resource-server \
    --user-pool-id "$USER_POOL_ID" \
    --identifier "$RESOURCE_SERVER_ID" \
    --name "AI Gateway" \
    --scopes ScopeName="$SCOPE_NAME",ScopeDescription="Invoke gateway tools" \
    --region "$REGION" >/dev/null
else
  aws cognito-idp create-resource-server \
    --user-pool-id "$USER_POOL_ID" \
    --identifier "$RESOURCE_SERVER_ID" \
    --name "AI Gateway" \
    --scopes ScopeName="$SCOPE_NAME",ScopeDescription="Invoke gateway tools" \
    --region "$REGION" >/dev/null
  echo "  ✅ Created resource server $RESOURCE_SERVER_ID (scope: $FULL_SCOPE)"
fi
echo ""

###############################################################################
# Step 3: Cognito M2M app client (client_credentials grant for the agent)
###############################################################################
echo "▶ Step 3: Cognito M2M app client..."

M2M_CLIENT_ID="$(aws cognito-idp list-user-pool-clients \
  --user-pool-id "$USER_POOL_ID" --max-results 60 --region "$REGION" \
  --query "UserPoolClients[?ClientName=='${M2M_CLIENT_NAME}'].ClientId | [0]" \
  --output text 2>/dev/null || echo "None")"

if [ -n "$M2M_CLIENT_ID" ] && [ "$M2M_CLIENT_ID" != "None" ]; then
  echo "  ⏭️  M2M client $M2M_CLIENT_NAME already exists ($M2M_CLIENT_ID)"
else
  M2M_CLIENT_ID="$(aws cognito-idp create-user-pool-client \
    --user-pool-id "$USER_POOL_ID" \
    --client-name "$M2M_CLIENT_NAME" \
    --generate-secret \
    --allowed-o-auth-flows client_credentials \
    --allowed-o-auth-scopes "$FULL_SCOPE" \
    --allowed-o-auth-flows-user-pool-client \
    --supported-identity-providers COGNITO \
    --region "$REGION" \
    --query 'UserPoolClient.ClientId' --output text)"
  echo "  ✅ Created M2M client ($M2M_CLIENT_ID)"
fi

M2M_CLIENT_SECRET="$(aws cognito-idp describe-user-pool-client \
  --user-pool-id "$USER_POOL_ID" --client-id "$M2M_CLIENT_ID" --region "$REGION" \
  --query 'UserPoolClient.ClientSecret' --output text)"

# Token endpoint derives from the user pool's Hosted UI domain prefix.
DOMAIN_PREFIX="$(aws cognito-idp describe-user-pool \
  --user-pool-id "$USER_POOL_ID" --region "$REGION" \
  --query 'UserPool.Domain' --output text 2>/dev/null || echo "None")"

if [ -z "$DOMAIN_PREFIX" ] || [ "$DOMAIN_PREFIX" = "None" ]; then
  echo "  ❌ User pool has no Hosted UI domain — cannot derive token endpoint."
  echo "     Configure a domain (deploy.sh Step 7) and re-run."
  exit 1
fi
TOKEN_ENDPOINT="https://${DOMAIN_PREFIX}.auth.${REGION}.amazoncognito.com/oauth2/token"
echo "     Token endpoint: $TOKEN_ENDPOINT"
echo ""

###############################################################################
# Step 4: Create the AgentCore Gateway (MCP + semantic discovery + JWT auth)
###############################################################################
echo "▶ Step 4: AgentCore Gateway..."

GATEWAY_ID="$($ACC list-gateways --max-results 100 \
  --query "items[?name=='${GATEWAY_NAME}'].gatewayId | [0]" \
  --output text 2>/dev/null || echo "None")"

if [ -n "$GATEWAY_ID" ] && [ "$GATEWAY_ID" != "None" ]; then
  echo "  ⏭️  Gateway $GATEWAY_NAME already exists ($GATEWAY_ID)"
else
  AUTH_CONFIG="$(jq -nc \
    --arg url "$DISCOVERY_URL" \
    --arg client "$M2M_CLIENT_ID" \
    '{ customJWTAuthorizer: { discoveryUrl: $url, allowedClients: [$client] } }')"

  PROTO_CONFIG='{"mcp":{"searchType":"SEMANTIC"}}'

  GATEWAY_ID="$($ACC create-gateway \
    --name "$GATEWAY_NAME" \
    --description "AI Gateway POC - MCP Tool Registry" \
    --role-arn "$ROLE_ARN" \
    --protocol-type "MCP" \
    --protocol-configuration "$PROTO_CONFIG" \
    --authorizer-type "CUSTOM_JWT" \
    --authorizer-configuration "$AUTH_CONFIG" \
    --query 'gatewayId' --output text)"
  echo "  ✅ Created gateway ($GATEWAY_ID) — waiting for READY..."
fi

# Poll until the gateway is READY (or fail fast).
STATUS="UNKNOWN"
for _ in $(seq 1 30); do
  STATUS="$($ACC get-gateway --gateway-identifier "$GATEWAY_ID" \
    --query 'status' --output text 2>/dev/null || echo "UNKNOWN")"
  [ "$STATUS" = "READY" ] && break
  if [ "$STATUS" = "FAILED" ]; then
    echo "  ❌ Gateway entered FAILED state"
    $ACC get-gateway --gateway-identifier "$GATEWAY_ID" --query 'statusReasons' --output json || true
    exit 1
  fi
  sleep 5
done

# Fail if the gateway never became READY — later target registration depends on it.
if [ "$STATUS" != "READY" ]; then
  echo "  ❌ Gateway did not reach READY (last status: $STATUS) after ~150s"
  exit 1
fi

GW_JSON="$($ACC get-gateway --gateway-identifier "$GATEWAY_ID" --output json)"
GATEWAY_URL="$(echo "$GW_JSON" | jq -r '.gatewayUrl')"
GATEWAY_ARN="$(echo "$GW_JSON" | jq -r '.gatewayArn')"
echo "     Status: $(echo "$GW_JSON" | jq -r '.status')"
echo "     URL:    $GATEWAY_URL"
echo ""

###############################################################################
# Step 5: Register Lambda targets (one per tool, schema from gateway-tools.json)
###############################################################################
echo "▶ Step 5: Registering MCP tool targets..."

# register_target <target-name> <tool-name> <lambda-arn>
#
# NOTE: AgentCore inline tool schemas only support a restricted JSON-Schema
# subset (type, properties, required, items, description). gateway-tools.json is
# authored within that subset (no `enum`), so the schema is used as-is here.
register_target() {
  local target_name="$1" tool_name="$2" lambda_arn="$3"

  local existing
  existing="$($ACC list-gateway-targets --gateway-identifier "$GATEWAY_ID" \
    --max-results 100 \
    --query "items[?name=='${target_name}'].targetId | [0]" \
    --output text 2>/dev/null || echo "None")"

  if [ -n "$existing" ] && [ "$existing" != "None" ]; then
    echo "  ⏭️  Target $target_name already exists ($existing)"
    return 0
  fi

  local tool_schema target_config cred_config
  tool_schema="$(jq -c --arg n "$tool_name" \
    '.tools[] | select(.name==$n) | {name, description, inputSchema}' "$TOOLS_JSON")"
  if [ -z "$tool_schema" ]; then
    echo "  ❌ Tool '$tool_name' not found in $TOOLS_JSON"; exit 1
  fi

  target_config="$(jq -nc --argjson tool "$tool_schema" --arg arn "$lambda_arn" \
    '{ mcp: { lambda: { lambdaArn: $arn, toolSchema: { inlinePayload: [$tool] } } } }')"
  cred_config='[{"credentialProviderType":"GATEWAY_IAM_ROLE"}]'

  local tid
  tid="$($ACC create-gateway-target \
    --gateway-identifier "$GATEWAY_ID" \
    --name "$target_name" \
    --description "AI Gateway POC tool: $tool_name" \
    --target-configuration "$target_config" \
    --credential-provider-configurations "$cred_config" \
    --query 'targetId' --output text)"
  echo "  ✅ Created target $target_name ($tid) — tool exposed as ${target_name}___${tool_name}"

  # Poll target until READY.
  local tstatus="UNKNOWN"
  for _ in $(seq 1 24); do
    tstatus="$($ACC get-gateway-target --gateway-identifier "$GATEWAY_ID" \
      --target-id "$tid" --query 'status' --output text 2>/dev/null || echo "UNKNOWN")"
    [ "$tstatus" = "READY" ] && break
    if [ "$tstatus" = "FAILED" ] || [ "$tstatus" = "SYNCHRONIZE_UNSUCCESSFUL" ]; then
      echo "  ⚠️  Target $target_name status: $tstatus"
      $ACC get-gateway-target --gateway-identifier "$GATEWAY_ID" --target-id "$tid" \
        --query 'statusReasons' --output json || true
      break
    fi
    sleep 5
  done

  # Warn (non-fatal) if the target never reached READY — the tool won't be
  # discoverable until it syncs, but the gateway itself is still usable.
  if [ "$tstatus" != "READY" ]; then
    echo "  ⚠️  Target $target_name did not reach READY (last status: $tstatus) — tool may be unavailable until it syncs"
  fi
}

register_target "search-kb"     "search_kb"     "$SEARCH_KB_ARN"
register_target "create-ticket" "create_ticket" "$CREATE_TICKET_ARN"
echo ""

###############################################################################
# Step 6: Write connection config for the demo agent and tests
###############################################################################
echo "▶ Step 6: Writing $OUT_FILE..."

jq -nc \
  --arg gw_name "$GATEWAY_NAME" \
  --arg gw_id "$GATEWAY_ID" \
  --arg gw_arn "$GATEWAY_ARN" \
  --arg gw_url "$GATEWAY_URL" \
  --arg region "$REGION" \
  --arg user_pool_id "$USER_POOL_ID" \
  --arg client_id "$M2M_CLIENT_ID" \
  --arg client_secret "$M2M_CLIENT_SECRET" \
  --arg token_endpoint "$TOKEN_ENDPOINT" \
  --arg scope "$FULL_SCOPE" \
  '{
    gatewayName: $gw_name,
    gatewayId: $gw_id,
    gatewayArn: $gw_arn,
    gatewayUrl: $gw_url,
    region: $region,
    userPoolId: $user_pool_id,
    auth: {
      clientId: $client_id,
      clientSecret: $client_secret,
      tokenEndpoint: $token_endpoint,
      scope: $scope
    },
    tools: ["search-kb___search_kb", "create-ticket___create_ticket"]
  }' > "$OUT_FILE"
chmod 600 "$OUT_FILE"
echo "  ✅ Wrote gateway connection details (contains M2M secret — gitignored)"
echo ""

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   ✅ Gateway ready with semantic discovery                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo "  Gateway URL: $GATEWAY_URL"
echo "  Tools:       search-kb___search_kb, create-ticket___create_ticket"
echo "  Config:      $OUT_FILE"
echo ""
echo "  Next: deploy the demo agent →"
echo "    bash scripts/deploy-demo-agent.sh $GATEWAY_NAME"
