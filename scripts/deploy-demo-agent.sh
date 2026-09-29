#!/bin/bash
# deploy-demo-agent.sh — Build the Strands demo agent as an ARM64 container,
# push it to ECR, and deploy it to AgentCore Runtime wired to the gateway.
#
# Usage:
#   ./deploy-demo-agent.sh [<gateway-name>]
#
# Reads gateway connection details from .agentcore-config.json (written by
# register-tools.sh). The gateway-name arg is optional and only used for log
# messages; the actual wiring comes from .agentcore-config.json.
#
# Region is read from AWS_REGION (falls back to us-east-1).
#
# AgentCore control-plane operations use the `aws bedrock-agentcore-control`
# service. Requires Docker with buildx (AgentCore Runtime images MUST be
# linux/arm64).

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$ROOT_DIR/.agentcore-config.json"
AGENT_DIR="$ROOT_DIR/custom-lambdas/demo-agent"

# Parse optional args: [<gateway-name>] [--company-name <name>] [--stage <stage>]
# gateway-name is the first positional arg if present (used for display only).
GATEWAY_NAME_ARG=""
COMPANY_NAME="${COMPANY_NAME:-anycompany}"
STAGE="${STAGE:-poc}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --company-name) COMPANY_NAME="$2"; shift 2 ;;
    --stage)        STAGE="$2";        shift 2 ;;
    --*)            echo "❌ Unknown option: $1"; exit 1 ;;
    *)              GATEWAY_NAME_ARG="$1"; shift ;;
  esac
done

# All resource names follow the same ${COMPANY_NAME}-${STAGE} convention so
# multiple deployments in the same account don't collide and destroy.sh can
# derive the correct names without extra state.
RUNTIME_NAME="${COMPANY_NAME}_${STAGE}_demo_agent"  # [a-zA-Z][a-zA-Z0-9_]{0,47}
ECR_REPO="${COMPANY_NAME}-${STAGE}-demo-agent"
IMAGE_TAG="latest"
EXEC_ROLE_NAME="${COMPANY_NAME}-${STAGE}-agent-runtime-role"
MODEL_ID="us.anthropic.claude-sonnet-4-6"
# Business unit -> Application Inference Profile map, shared with the API Gateway
# streaming proxy so chat and agent traffic attribute cost the same way.
TEAM_CONFIG_TABLE="ai-gateway-team-config"

# Business unit charged when an invoke does not name one. Without it such turns fall back
# to the raw model id and their spend lands in the unattributed "General" pool. A
# caller-supplied business_unit still wins, so this does not pin the agent to one BU.
#
# IT-Operations is the default because this agent is the IT support assistant, and because
# the approved spec (.kiro/specs/agent-aip-cost-attribution/requirements.md, Requirement
# 1.1) calls for agent traffic to attribute there. Per-caller attribution is still
# honoured, which the spec's single-ARN approach would have precluded: pinning the runtime
# to one profile would bill an Architecture user's turns to IT-Operations, and the request
# would still succeed, so the error would be invisible.
#
# Passed as a business unit name rather than a profile ARN so the agent resolves it through
# the same DynamoDB table as every other lookup — one source of truth, and the entitlement
# rules apply to the default too. Falls back to the first active unit in the matrix if
# IT-Operations is absent. Override with DEFAULT_BUSINESS_UNIT in the environment.
#
# The literal fallback at the end matters: previously, if jq was unavailable or the matrix
# file was not found, DEFAULT_BU ended up empty and the environment variable was omitted
# entirely. The deploy still reported success, so the loss of attribution was invisible
# until someone noticed spend sitting in the unattributed pool. Naming a business unit that
# turns out not to be provisioned is harmless by comparison — the agent's lookup falls
# through to the raw model and says so in its logs.
MATRIX_FILE="$ROOT_DIR/config/bu-models.json"
PREFERRED_DEFAULT_BU="IT-Operations"
DEFAULT_BU="${DEFAULT_BUSINESS_UNIT:-}"
if [ -z "$DEFAULT_BU" ] && [ -f "$MATRIX_FILE" ] && command -v jq >/dev/null 2>&1; then
  DEFAULT_BU="$(jq -r --arg want "$PREFERRED_DEFAULT_BU" '
    (first(.businessUnits[] | select(.active and .team == $want) | .team))
    // (first(.businessUnits[] | select(.active) | .team))
    // empty' "$MATRIX_FILE" 2>/dev/null || echo "")"
fi
if [ -z "$DEFAULT_BU" ]; then
  DEFAULT_BU="$PREFERRED_DEFAULT_BU"
  DEFAULT_BU_SOURCE="literal fallback (matrix or jq unavailable)"
elif [ -n "${DEFAULT_BUSINESS_UNIT:-}" ]; then
  DEFAULT_BU_SOURCE="DEFAULT_BUSINESS_UNIT environment override"
else
  DEFAULT_BU_SOURCE="config/bu-models.json"
fi

ACC="aws bedrock-agentcore-control --region $REGION"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   Deploy Demo Agent to AgentCore Runtime                     ║"
echo "╚══════════════════════════════════════════════════════════════╝"

###############################################################################
# Step 0: Preconditions
###############################################################################
if [ ! -f "$CONFIG_FILE" ]; then
  echo "❌ $CONFIG_FILE not found."
  echo "   Run scripts/register-tools.sh first to create the gateway."
  exit 1
fi

command -v docker >/dev/null 2>&1 || command -v finch >/dev/null 2>&1 || { echo "❌ docker or finch is required"; exit 1; }

# Use finch as a drop-in if docker is not available.
DOCKER_CMD="docker"
if ! command -v docker >/dev/null 2>&1 && command -v finch >/dev/null 2>&1; then
  DOCKER_CMD="finch"
  echo "  ℹ️  docker not found — using finch"
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

GATEWAY_URL="$(jq -r '.gatewayUrl // empty' "$CONFIG_FILE")"
GW_CLIENT_ID="$(jq -r '.auth.clientId // empty' "$CONFIG_FILE")"
GW_CLIENT_SECRET="$(jq -r '.auth.clientSecret // empty' "$CONFIG_FILE")"
GW_TOKEN_ENDPOINT="$(jq -r '.auth.tokenEndpoint // empty' "$CONFIG_FILE")"
GW_SCOPE="$(jq -r '.auth.scope // empty' "$CONFIG_FILE")"

# Fail here rather than at invoke time.
#
# `jq -r` on a missing key yields the string "null", which was previously injected
# verbatim into the runtime environment (GATEWAY_MCP_URL=null). The deploy reported
# success and the agent then failed on every invocation with a 500, which is the most
# expensive place to discover a missing config value. `// empty` above turns a missing
# key into an empty string so this check can catch it.
MISSING_KEYS=""
[ -z "$GATEWAY_URL" ]        && MISSING_KEYS="${MISSING_KEYS}  .gatewayUrl (-> GATEWAY_MCP_URL)\n"
[ -z "$GW_CLIENT_ID" ]       && MISSING_KEYS="${MISSING_KEYS}  .auth.clientId (-> GATEWAY_CLIENT_ID)\n"
[ -z "$GW_TOKEN_ENDPOINT" ]  && MISSING_KEYS="${MISSING_KEYS}  .auth.tokenEndpoint (-> GATEWAY_TOKEN_ENDPOINT)\n"
[ -z "$GW_SCOPE" ]           && MISSING_KEYS="${MISSING_KEYS}  .auth.scope (-> GATEWAY_SCOPE)\n"

if [ -n "$MISSING_KEYS" ]; then
  echo "❌ $CONFIG_FILE is missing required gateway values:"
  printf "%b" "$MISSING_KEYS"
  echo "   Re-run scripts/register-tools.sh to regenerate the gateway configuration."
  exit 1
fi

# The client secret is only required when the Identity token vault is not in use; the
# check for that lives with the env-var construction below, where the vault is resolved.

# Optional AgentCore primitives (set by setup-agentcore-memory.py / -identity.py).
MEMORY_ID="$(jq -r '.memory.memoryId // empty' "$CONFIG_FILE")"
OAUTH_PROVIDER="$(jq -r '.identity.oauth2ProviderName // empty' "$CONFIG_FILE")"

echo "  Runtime:     $RUNTIME_NAME"
echo "  Model:       $MODEL_ID (fallback; per-BU profile resolved at invoke time)"
echo "  Team config: $TEAM_CONFIG_TABLE"
echo "  Default BU:  $DEFAULT_BU (used when an invoke omits business_unit)"
echo "               source: $DEFAULT_BU_SOURCE"
if [ "$DEFAULT_BU_SOURCE" = "literal fallback (matrix or jq unavailable)" ]; then
  echo "  ⚠️  Could not read config/bu-models.json (missing file, or jq not installed)."
  echo "      Defaulting to '$PREFERRED_DEFAULT_BU'. If that business unit has no row in"
  echo "      $TEAM_CONFIG_TABLE, invokes without an explicit business_unit will be"
  echo "      UNATTRIBUTED. Run scripts/create-aips.sh then"
  echo "      scripts/create-team-config-table.sh to provision it."
fi
echo "  Gateway URL: $GATEWAY_URL"
echo "  Memory:      ${MEMORY_ID:-<none>}"
echo "  Identity:    ${OAUTH_PROVIDER:-<none>}"
echo "  Region:      $REGION"
echo ""

###############################################################################
# Step 1: ECR repository
###############################################################################
echo "▶ Step 1: ECR repository..."
if aws ecr describe-repositories --repository-names "$ECR_REPO" --region "$REGION" >/dev/null 2>&1; then
  echo "  ⏭️  Repository $ECR_REPO already exists"
else
  aws ecr create-repository --repository-name "$ECR_REPO" \
    --image-scanning-configuration scanOnPush=true \
    --tags Key=Application,Value=AIGatewayPOC Key=CostCenter,Value=IT-Operations \
    --region "$REGION" >/dev/null
  echo "  ✅ Created repository $ECR_REPO"
fi
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}"
IMAGE_URI="${ECR_URI}:${IMAGE_TAG}"
echo ""

###############################################################################
# Step 2: Build + push ARM64 image
###############################################################################
echo "▶ Step 2: Building ARM64 image and pushing to ECR..."
aws ecr get-login-password --region "$REGION" \
  | $DOCKER_CMD login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

if [ "$DOCKER_CMD" = "finch" ]; then
  # Finch supports --platform natively without buildx.
  # --push is not supported by finch build; push separately.
  $DOCKER_CMD build \
    --platform linux/arm64 \
    --tag "$IMAGE_URI" \
    "$AGENT_DIR"
  $DOCKER_CMD push "$IMAGE_URI"
else
  # Ensure a buildx builder exists for cross-platform builds.
  if ! docker buildx inspect ai-gateway-builder >/dev/null 2>&1; then
    docker buildx create --name ai-gateway-builder --use >/dev/null
  else
    docker buildx use ai-gateway-builder
  fi

  docker buildx build \
    --platform linux/arm64 \
    --tag "$IMAGE_URI" \
    --push \
    "$AGENT_DIR"
fi
echo "  ✅ Pushed $IMAGE_URI"
echo ""

###############################################################################
# Step 3: Execution role for the runtime
###############################################################################
echo "▶ Step 3: AgentCore Runtime execution role..."
EXEC_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${EXEC_ROLE_NAME}"

TRUST_POLICY="$(jq -nc --arg acct "$ACCOUNT_ID" \
  '{
    Version: "2012-10-17",
    Statement: [{
      Effect: "Allow",
      Principal: { Service: "bedrock-agentcore.amazonaws.com" },
      Action: "sts:AssumeRole",
      Condition: { StringEquals: { "aws:SourceAccount": $acct } }
    }]
  }')"

if aws iam get-role --role-name "$EXEC_ROLE_NAME" >/dev/null 2>&1; then
  echo "  ⏭️  Role $EXEC_ROLE_NAME already exists"
  aws iam update-assume-role-policy --role-name "$EXEC_ROLE_NAME" \
    --policy-document "$TRUST_POLICY" >/dev/null
else
  aws iam create-role --role-name "$EXEC_ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --description "AI Gateway - AgentCore Runtime execution role" \
    --tags Key=Application,Value=AIGatewayPOC Key=CostCenter,Value=IT-Operations >/dev/null
  echo "  ✅ Created role $EXEC_ROLE_NAME"
fi

EXEC_POLICY="$(jq -nc \
  --arg region "$REGION" \
  --arg acct "$ACCOUNT_ID" \
  --arg repo_arn "arn:aws:ecr:${REGION}:${ACCOUNT_ID}:repository/${ECR_REPO}" \
  --arg team_table "$TEAM_CONFIG_TABLE" \
  '{
    Version: "2012-10-17",
    Statement: [
      {
        Sid: "EcrAuth",
        Effect: "Allow",
        Action: "ecr:GetAuthorizationToken",
        Resource: "*"
      },
      {
        Sid: "EcrPull",
        Effect: "Allow",
        Action: ["ecr:BatchGetImage","ecr:GetDownloadUrlForLayer","ecr:BatchCheckLayerAvailability"],
        Resource: $repo_arn
      },
      {
        Sid: "Logs",
        Effect: "Allow",
        Action: ["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents","logs:DescribeLogStreams"],
        Resource: ("arn:aws:logs:" + $region + ":" + $acct + ":log-group:/aws/bedrock-agentcore/*")
      },
      {
        Sid: "Xray",
        Effect: "Allow",
        Action: ["xray:PutTraceSegments","xray:PutTelemetryRecords","xray:GetSamplingRules","xray:GetSamplingTargets"],
        Resource: "*"
      },
      # GetInferenceProfile is NOT required to invoke an Application Inference Profile —
      # the streaming proxy role holds only the Invoke actions and invokes profiles
      # successfully. It is granted here solely for diagnose_model_access(), which calls
      # it to distinguish a genuinely malformed ARN from an unauthorised profile when
      # Bedrock reports the unhelpful "The provided model identifier is invalid".
      #
      # (An earlier revision of this comment claimed Bedrock needed it to resolve the
      # profile. That was wrong: the real cause of the failures being debugged at the
      # time was a whitespace-padded ARN, plus the missing token-vault permissions below.)
      {
        Sid: "BedrockInvoke",
        Effect: "Allow",
        Action: [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock:GetInferenceProfile"
        ],
        Resource: "*"
      },
      {
        Sid: "TeamConfigLookup",
        Effect: "Allow",
        Action: "dynamodb:GetItem",
        Resource: ("arn:aws:dynamodb:" + $region + ":" + $acct + ":table/" + $team_table)
      },
      {
        Sid: "AgentCoreMemory",
        Effect: "Allow",
        Action: [
          "bedrock-agentcore:CreateEvent",
          "bedrock-agentcore:ListEvents",
          "bedrock-agentcore:GetEvent",
          "bedrock-agentcore:RetrieveMemoryRecords",
          "bedrock-agentcore:ListMemoryRecords"
        ],
        Resource: ("arn:aws:bedrock-agentcore:" + $region + ":" + $acct + ":memory/*")
      },
      # Token vault access needs three things, and missing any one of them makes the
      # agent silently fall back to direct M2M — which cannot work, because
      # GATEWAY_CLIENT_SECRET is intentionally absent from the environment whenever a
      # vault provider is configured:
      #   1. the GetResourceOauth2Token / GetWorkloadAccessToken* actions,
      #   2. Create/Get/ListWorkloadIdentities, since the identity SDK lazily creates a
      #      workload identity for the calling workload on the first token request, and
      #   3. secretsmanager:GetSecretValue on the AgentCore-managed secret that backs the
      #      OAuth2 credential provider (named bedrock-agentcore-identity!default/oauth2/*).
      {
        Sid: "AgentCoreIdentityTokenVault",
        Effect: "Allow",
        Action: [
          "bedrock-agentcore:GetResourceOauth2Token",
          "bedrock-agentcore:GetWorkloadAccessToken",
          "bedrock-agentcore:GetWorkloadAccessTokenForJWT",
          "bedrock-agentcore:GetWorkloadAccessTokenForUserId",
          "bedrock-agentcore:CreateWorkloadIdentity",
          "bedrock-agentcore:GetWorkloadIdentity",
          "bedrock-agentcore:ListWorkloadIdentities"
        ],
        Resource: [
          ("arn:aws:bedrock-agentcore:" + $region + ":" + $acct + ":token-vault/*"),
          ("arn:aws:bedrock-agentcore:" + $region + ":" + $acct + ":workload-identity-directory/*")
        ]
      },
      {
        Sid: "AgentCoreIdentitySecret",
        Effect: "Allow",
        Action: "secretsmanager:GetSecretValue",
        Resource: ("arn:aws:secretsmanager:" + $region + ":" + $acct + ":secret:bedrock-agentcore-identity!*")
      }
    ]
  }')"

aws iam put-role-policy --role-name "$EXEC_ROLE_NAME" \
  --policy-name "agent-runtime-access" \
  --policy-document "$EXEC_POLICY" >/dev/null
echo "  ✅ Attached execution policy"
echo "     Waiting 10s for IAM propagation..."
sleep 10
echo ""

###############################################################################
# Step 4: Create or update the AgentCore Runtime
###############################################################################
echo "▶ Step 4: AgentCore Runtime..."

ARTIFACT="$(jq -nc --arg uri "$IMAGE_URI" \
  '{ containerConfiguration: { containerUri: $uri } }')"
NET_CONFIG='{"networkMode":"PUBLIC"}'
PROTO_CONFIG='{"serverProtocol":"HTTP"}'

# When AgentCore Identity is configured (OAUTH_PROVIDER set), the client secret
# lives in the token vault and the agent fetches tokens from there. In that case
# we deliberately OMIT GATEWAY_CLIENT_SECRET from the runtime environment so the
# secret is never exposed as a plaintext env var — this is the whole point of the
# Identity work. Without a provider (e.g. no Identity), the secret is injected so
# the agent can use the direct Cognito client_credentials flow.
if [ -n "$OAUTH_PROVIDER" ]; then
  echo "  🔒 Identity provider set — omitting GATEWAY_CLIENT_SECRET from runtime env (token vault in use)"
else
  echo "  ⚠️  No Identity provider — injecting GATEWAY_CLIENT_SECRET as env var (direct M2M)"
fi

ENV_VARS="$(jq -nc \
  --arg url "$GATEWAY_URL" \
  --arg cid "$GW_CLIENT_ID" \
  --arg secret "$GW_CLIENT_SECRET" \
  --arg token "$GW_TOKEN_ENDPOINT" \
  --arg scope "$GW_SCOPE" \
  --arg memid "$MEMORY_ID" \
  --arg provider "$OAUTH_PROVIDER" \
  --arg team_table "$TEAM_CONFIG_TABLE" \
  --arg default_bu "$DEFAULT_BU" \
  '{
    GATEWAY_MCP_URL: $url,
    GATEWAY_CLIENT_ID: $cid,
    GATEWAY_TOKEN_ENDPOINT: $token,
    GATEWAY_SCOPE: $scope,
    TEAM_CONFIG_TABLE: $team_table
  }
  + (if $default_bu != "" then {DEFAULT_BUSINESS_UNIT: $default_bu} else {} end)
  + (if $provider != "" then {GATEWAY_OAUTH_PROVIDER: $provider} else {GATEWAY_CLIENT_SECRET: $secret} end)
  + (if $memid != "" then {AGENTCORE_MEMORY_ID: $memid} else {} end)')"

# The runtime uses default IAM (SigV4) inbound auth so it can be invoked with
# `aws bedrock-agentcore invoke-agent-runtime`. No JWT authorizer is set.

EXISTING_ID="$($ACC list-agent-runtimes --max-results 100 \
  --query "agentRuntimes[?agentRuntimeName=='${RUNTIME_NAME}'].agentRuntimeId | [0]" \
  --output text 2>/dev/null || echo "None")"

if [ -n "$EXISTING_ID" ] && [ "$EXISTING_ID" != "None" ]; then
  echo "  ⏭️  Runtime $RUNTIME_NAME exists ($EXISTING_ID) — updating to new image version..."
  $ACC update-agent-runtime \
    --agent-runtime-id "$EXISTING_ID" \
    --agent-runtime-artifact "$ARTIFACT" \
    --role-arn "$EXEC_ROLE_ARN" \
    --network-configuration "$NET_CONFIG" \
    --protocol-configuration "$PROTO_CONFIG" \
    --environment-variables "$ENV_VARS" >/dev/null
  RUNTIME_ID="$EXISTING_ID"
  echo "  ✅ Update submitted (new version)"
else
  RUNTIME_ID="$($ACC create-agent-runtime \
    --agent-runtime-name "$RUNTIME_NAME" \
    --description "AI Gateway Demo Agent - IT Support Assistant" \
    --agent-runtime-artifact "$ARTIFACT" \
    --role-arn "$EXEC_ROLE_ARN" \
    --network-configuration "$NET_CONFIG" \
    --protocol-configuration "$PROTO_CONFIG" \
    --environment-variables "$ENV_VARS" \
    --query 'agentRuntimeId' --output text)"
  echo "  ✅ Created runtime ($RUNTIME_ID)"
fi

# Poll until READY.
STATUS="UNKNOWN"
for _ in $(seq 1 60); do
  STATUS="$($ACC get-agent-runtime --agent-runtime-id "$RUNTIME_ID" \
    --query 'status' --output text 2>/dev/null || echo "UNKNOWN")"
  [ "$STATUS" = "READY" ] && break
  if [ "$STATUS" = "CREATE_FAILED" ] || [ "$STATUS" = "UPDATE_FAILED" ]; then
    echo "  ❌ Runtime entered $STATUS"
    $ACC get-agent-runtime --agent-runtime-id "$RUNTIME_ID" --query 'failureReason' --output text || true
    exit 1
  fi
  sleep 5
done

# Fail explicitly if the loop timed out without reaching READY, rather than
# continuing and reporting success on a runtime that isn't actually serving.
if [ "$STATUS" != "READY" ]; then
  echo "  ❌ Runtime did not reach READY (last status: $STATUS) after ~300s"
  exit 1
fi

RUNTIME_ARN="$($ACC get-agent-runtime --agent-runtime-id "$RUNTIME_ID" \
  --query 'agentRuntimeArn' --output text)"
echo "     Status:  $($ACC get-agent-runtime --agent-runtime-id "$RUNTIME_ID" --query 'status' --output text)"
echo "     ARN:     $RUNTIME_ARN"
echo ""

# Persist the runtime ARN back into the config for tests/cleanup.
tmp="$(mktemp)"
jq --arg arn "$RUNTIME_ARN" --arg id "$RUNTIME_ID" --arg name "$RUNTIME_NAME" \
  '. + {agentRuntimeArn: $arn, agentRuntimeId: $id, agentRuntimeName: $name}' \
  "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   ✅ Demo agent deployed to AgentCore Runtime                 ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo "  Test it (pass the payload as a file — the CLI base64-mangles inline blobs):"
echo "    echo '{\"prompt\":\"Find documents about tire pressure monitoring\",\"business_unit\":\"Architecture\"}' > /tmp/payload.json"
echo "    aws bedrock-agentcore invoke-agent-runtime \\"
echo "      --agent-runtime-arn $RUNTIME_ARN \\"
echo "      --payload fileb:///tmp/payload.json \\"
echo "      --region $REGION /dev/stdout"
echo ""
echo "  The response echoes model_id + cost_attributed. When business_unit matches a row"
echo "  in $TEAM_CONFIG_TABLE, tokens land on that BU's series in the CloudWatch dashboard."
echo "  Omit business_unit and the turn falls back to $MODEL_ID (\"General\" series)."
