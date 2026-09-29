#!/bin/bash

# AI Gateway POC — Main Deployment Orchestrator (Idempotent)
# Usage: ./deploy.sh --region <aws-region> [--stage poc] [--alert-email <email>]
#
# This script is fully idempotent and resumable. Re-run at any time and it will
# skip steps that are already completed, then continue from where it left off.

set -e

# Prevent macOS git credential popup on public repos (Issue 2 fix)
export GIT_TERMINAL_PROMPT=0

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   AI Gateway POC — Deployment Script                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

###############################################################################
# Python virtual environment setup (idempotent)
###############################################################################
echo "Setting up Python virtual environment..."

if ! command -v python3 &>/dev/null; then
  echo "❌ python3 is required but not found. Install it and re-run."
  exit 1
fi

# Create .venv if it doesn't exist
if [ ! -d ".venv" ]; then
  echo "  📦 Creating .venv..."
  python3 -m venv .venv
fi

# Activate for this script's session
# shellcheck source=/dev/null
source .venv/bin/activate

# Install/upgrade required packages quietly
echo "  📦 Installing Python dependencies..."
pip3 install -q --upgrade \
  boto3 \
  botocore \
  requests \
  opensearch-py \
  requests-aws4auth \
  'bedrock-agentcore[strands-agents]>=1.0.3'

echo "  ✅ Python environment ready ($(python3 --version), .venv/)"
echo ""

###############################################################################
# Prerequisite checks
###############################################################################
echo "Checking prerequisites..."

MISSING=""
command -v node &>/dev/null || MISSING="${MISSING} node"
command -v npm  &>/dev/null || MISSING="${MISSING} npm"
command -v aws  &>/dev/null || MISSING="${MISSING} aws-cli"
command -v jq   &>/dev/null || MISSING="${MISSING} jq"
command -v git  &>/dev/null || MISSING="${MISSING} git"

if [ -n "$MISSING" ]; then
  echo "❌ Missing required tools:${MISSING}"
  echo "   Install them and re-run this script."
  exit 1
fi

echo "  ✅ All prerequisites satisfied"

# Warn if AWS CLI is too old for AgentCore
CLI_VERSION=$(aws --version 2>&1 | grep -o 'aws-cli/[0-9.]*' | cut -d/ -f2)
CLI_MAJOR=$(echo "$CLI_VERSION" | cut -d. -f1)
CLI_MINOR=$(echo "$CLI_VERSION" | cut -d. -f2)
if [ "$CLI_MAJOR" -eq 2 ] && [ "$CLI_MINOR" -lt 28 ]; then
  echo ""
  echo "  ⚠️  AWS CLI ${CLI_VERSION} detected — AgentCore requires >= 2.28"
  echo "     Steps 5, 5a, 5b, 12, 12a will be skipped."
  echo "     Upgrade: curl https://awscli.amazonaws.com/AWSCLIV2.pkg -o /tmp/AWSCLIV2.pkg && sudo installer -pkg /tmp/AWSCLIV2.pkg -target /"
fi

echo ""

###############################################################################
# Parse arguments
###############################################################################
REGION=""
STAGE="poc"
COMPANY_NAME="anycompany"
ALERT_EMAIL=""
PROFILE="${AWS_PROFILE:-}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --region)
      REGION="$2"
      shift 2
      ;;
    --stage)
      STAGE="$2"
      shift 2
      ;;
    --company-name)
      COMPANY_NAME="$2"
      shift 2
      ;;
    --alert-email)
      ALERT_EMAIL="$2"
      shift 2
      ;;
    --profile)
      PROFILE="$2"
      shift 2
      ;;
    --temp-password)
      COGNITO_TEMP_PASSWORD="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: bash deploy.sh --region <aws-region> [--stage <stage>] [--company-name <name>] [--alert-email <email>] [--temp-password <pwd>] [--profile <aws-profile>]"
      echo ""
      echo "Options:"
      echo "  --region         AWS region to deploy into (required). Example: us-east-1"
      echo "  --stage          Deployment stage suffix for stack names (default: poc)"
      echo "  --company-name   Prefix for all AWS resource names (default: anycompany)"
      echo "  --alert-email    Email for AWS Budget alert notifications"
      echo "  --profile        AWS named profile to use (default: AWS default credential chain)"
      echo "  --temp-password  Temporary password for new Cognito users (prompted interactively"
      echo "                   if omitted; can also be set via COGNITO_TEMP_PASSWORD env var)"
      echo "  --help           Show this help message"
      exit 0
      ;;
    *)
      echo "❌ Unknown parameter: $1"
      echo "Usage: bash deploy.sh --region <aws-region> [--stage poc] [--company-name anycompany] [--alert-email <email>] [--temp-password <pwd>] [--profile <aws-profile>]"
      echo "Run 'bash deploy.sh --help' for full usage."
      exit 1
      ;;
  esac
done

# Validate required parameters
if [ -z "$REGION" ]; then
  echo "❌ ERROR: --region is required"
  echo "Usage: ./deploy.sh --region <aws-region> [--stage poc] [--alert-email <email>]"
  exit 1
fi

if [ -z "$ALERT_EMAIL" ]; then
  read -rp "Enter alert email for budget notifications: " ALERT_EMAIL
  if [ -z "$ALERT_EMAIL" ]; then
    echo "❌ ERROR: --alert-email is required for budget alert subscription"
    exit 1
  fi
fi

# Derive stack names
GATEWAY_STACK="${COMPANY_NAME}-ai-gateway-${STAGE}"
CUSTOM_LAMBDAS_STACK="${COMPANY_NAME}-mcp-tools-${STAGE}"
FRONTEND_STACK="${COMPANY_NAME}-frontend-${STAGE}"

# Export region and profile for all child scripts and AWS CLI calls
export AWS_REGION="$REGION"
export AWS_DEFAULT_REGION="$REGION"
[ -n "$PROFILE" ] && export AWS_PROFILE="$PROFILE"

echo "Configuration:"
echo "  Region:      $REGION"
echo "  Stage:       $STAGE"
echo "  Profile:     ${PROFILE:-<default>}"
echo "  Alert Email: $ALERT_EMAIL"
echo ""

###############################################################################
# Preflight: Docker / Finch check
# Step 12 builds an ARM64 container for the demo agent. If neither Docker nor
# Finch is running the step is skipped silently — warn now so you're not
# surprised 45 minutes into the deploy.
###############################################################################
if { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }; then
  echo "  ✅ Docker is running — Step 12 (demo agent build) will proceed"
elif { command -v finch >/dev/null 2>&1 && finch info >/dev/null 2>&1; }; then
  echo "  ✅ Finch is running — Step 12 (demo agent build) will proceed"
else
  echo "  ⚠️  Docker / Finch not detected or not running."
  echo "     Step 12 (demo agent ARM64 build) will be SKIPPED."
  echo "     To include it: start Docker Desktop or run 'finch vm start',"
  echo "     then re-run: bash scripts/deploy-demo-agent.sh --company-name $COMPANY_NAME --stage $STAGE"
fi
echo ""

###############################################################################
# Helper: deploy or update a CloudFormation stack (idempotent)
###############################################################################
deploy_stack() {
  local stack_name="$1"
  local template_file="$2"
  shift 2
  local extra_args=("$@")

  if aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" >/dev/null 2>&1; then
    local status
    status=$(aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" \
      --query 'Stacks[0].StackStatus' --output text)

    if [[ "$status" == "ROLLBACK_COMPLETE" || "$status" == "DELETE_FAILED" ]]; then
      echo "  ⚠️  Stack in ${status} state — deleting before re-create..."
      aws cloudformation delete-stack --stack-name "$stack_name" --region "$REGION"
      aws cloudformation wait stack-delete-complete --stack-name "$stack_name" --region "$REGION"
    else
      echo "  ⏭️  Stack ${stack_name} exists (${status}), attempting update..."
      # Distinguish "nothing to do" from a real rejection. Discarding stderr and calling
      # every failure "No updates needed" hides genuine errors — an invalid parameter, a
      # malformed template, or an unsupported UsePreviousValue — as a reassuring message.
      local update_err
      if update_err=$(aws cloudformation update-stack \
        --stack-name "$stack_name" \
        --template-body "file://${template_file}" \
        --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
        "${extra_args[@]}" \
        --region "$REGION" 2>&1); then
        echo "  ⏳ Waiting for stack update..."
        aws cloudformation wait stack-update-complete --stack-name "$stack_name" --region "$REGION"
      elif echo "$update_err" | grep -q "No updates are to be performed"; then
        echo "  ℹ️  No updates needed"
      else
        echo "  ❌ Stack update rejected for ${stack_name}:"
        echo "$update_err" | sed 's/^/       /'
        return 1
      fi
      return 0
    fi
  fi

  # Create the stack (either fresh or after cleanup of failed state)
  aws cloudformation create-stack \
    --stack-name "$stack_name" \
    --template-body "file://${template_file}" \
    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
    "${extra_args[@]}" \
    --region "$REGION"
  echo "  ⏳ Waiting for stack creation..."
  aws cloudformation wait stack-create-complete --stack-name "$stack_name" --region "$REGION"
}

###############################################################################
# Step 1: Deploy AI Gateway CloudFormation stack
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 1: Deploying AI Gateway stack..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Pass the frontend origin into the gateway stack when it is already known, so the
# template — not a post-deploy patch — owns the Cognito OAuth callback URLs.
#
# On a first deploy the frontend stack does not exist yet (it is Step 10), so the URL is
# unknown and Step 8 patches the app client afterwards. That patch leaves the client
# permanently drifted from the template, which is why any later stack update silently
# reverted sign-in to localhost. From the second deploy onward the URL is available, so it
# is passed here and the drift resolves itself.
#
# UsePreviousValue on the other three parameters is essential. Supplying --parameters
# partially makes CloudFormation fall back to template defaults for anything omitted, and
# the default CognitoDomainPrefix differs from what is deployed — which would replace the
# Cognito domain and break sign-in. That is the failure that put this stack into
# UPDATE_ROLLBACK_COMPLETE before.
GATEWAY_PARAMS=()
EXISTING_CF_URL=$(aws cloudformation describe-stacks --stack-name "$FRONTEND_STACK" \
  --query 'Stacks[0].Outputs[?OutputKey==`CloudFrontURL`].OutputValue' \
  --output text --region "$REGION" 2>/dev/null || echo "")

if [ -n "$EXISTING_CF_URL" ] && [ "$EXISTING_CF_URL" != "None" ]; then
  # Normalise: the output is a bare domain, the parameter wants an origin.
  FRONTEND_ORIGIN="${EXISTING_CF_URL%/}"
  [[ "$FRONTEND_ORIGIN" != https://* ]] && FRONTEND_ORIGIN="https://${FRONTEND_ORIGIN}"

  # UsePreviousValue is only valid on update-stack. deploy_stack deletes and re-creates a
  # stack that is in ROLLBACK_COMPLETE or DELETE_FAILED, and create-stack rejects it — so
  # the flag can only be used when the stack exists AND will actually be updated.
  GATEWAY_STACK_STATUS=$(aws cloudformation describe-stacks --stack-name "$GATEWAY_STACK" \
    --query 'Stacks[0].StackStatus' --output text --region "$REGION" 2>/dev/null || echo "")

  case "$GATEWAY_STACK_STATUS" in
    ""|ROLLBACK_COMPLETE|DELETE_FAILED)
      GATEWAY_PARAMS=(--parameters "ParameterKey=FrontendURL,ParameterValue=${FRONTEND_ORIGIN}")
      ;;
    *)
      GATEWAY_PARAMS=(--parameters
        "ParameterKey=FrontendURL,ParameterValue=${FRONTEND_ORIGIN}"
        "ParameterKey=CognitoDomainPrefix,UsePreviousValue=true"
        "ParameterKey=CallbackURL,UsePreviousValue=true"
        "ParameterKey=LogoutURL,UsePreviousValue=true")
      ;;
  esac
  echo "  Passing FrontendURL=${FRONTEND_ORIGIN} so the template owns the OAuth URLs"
else
  echo "  ℹ️  Frontend stack not deployed yet — OAuth URLs will be patched in Step 8."
  echo "     Re-running deploy.sh afterwards lets the template take ownership."
fi

deploy_stack "$GATEWAY_STACK" "cloudformation/gateway-stack.yaml" "${GATEWAY_PARAMS[@]}"

# Get Gateway outputs
GATEWAY_URL=$(aws cloudformation describe-stacks --stack-name "$GATEWAY_STACK" \
  --query 'Stacks[0].Outputs[?OutputKey==`GatewayUrl`].OutputValue' \
  --output text --region "$REGION")

USER_POOL_ID=$(aws cloudformation describe-stacks --stack-name "$GATEWAY_STACK" \
  --query 'Stacks[0].Outputs[?OutputKey==`UserPoolId`].OutputValue' \
  --output text --region "$REGION")

APP_CLIENT_ID=$(aws cloudformation describe-stacks --stack-name "$GATEWAY_STACK" \
  --query 'Stacks[0].Outputs[?OutputKey==`AppClientId`].OutputValue' \
  --output text --region "$REGION")

API_ID=$(aws cloudformation describe-stacks --stack-name "$GATEWAY_STACK" \
  --query 'Stacks[0].Outputs[?OutputKey==`ApiId`].OutputValue' \
  --output text --region "$REGION")

# Read the Hosted UI domain from the stack rather than assuming it. The domain prefix
# must be globally unique, so deployments routinely end up with something other than
# the template default. Hardcoding it here previously wrote a nonexistent login URL
# into the frontend config and broke sign-in.
COGNITO_DOMAIN_URL=$(aws cloudformation describe-stacks --stack-name "$GATEWAY_STACK" \
  --query 'Stacks[0].Outputs[?OutputKey==`CognitoDomain`].OutputValue' \
  --output text --region "$REGION")

echo "  ✅ AI Gateway deployed"
echo "     Gateway URL: ${GATEWAY_URL}"
echo ""

###############################################################################
# Step 2: Enable Bedrock invocation logging
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 2: Setting up Bedrock invocation logging..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

LOGGING_CONFIG=$(aws bedrock get-model-invocation-logging-configuration \
  --region "$REGION" --query 'loggingConfig' --output json 2>/dev/null || echo "{}")

LOG_GROUP_NAME=$(echo "$LOGGING_CONFIG" | jq -r '.cloudWatchConfig.logGroupName // empty' 2>/dev/null || echo "")

# Check both that logging is configured AND the log group actually exists.
# The log group may have been deleted during a previous teardown while the
# config remained, causing new invocations to silently drop logs.
LOG_GROUP_EXISTS=""
if [ -n "$LOG_GROUP_NAME" ]; then
  LOG_GROUP_EXISTS=$(aws logs describe-log-groups \
    --log-group-name-prefix "$LOG_GROUP_NAME" \
    --region "$REGION" \
    --query "logGroups[?logGroupName=='${LOG_GROUP_NAME}'].logGroupName" \
    --output text 2>/dev/null || echo "")
fi

if [ -n "$LOG_GROUP_NAME" ] && [ -n "$LOG_GROUP_EXISTS" ]; then
  echo "  ⏭️  Invocation logging already configured — skipping"
else
  python3 scripts/enable-logging.py --region "$REGION" --company-name "$COMPANY_NAME" --stage "$STAGE"
  echo "  ✅ Invocation logging enabled"
fi

echo ""

###############################################################################
# Step 3: Create Application Inference Profiles for BU cost attribution
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 3: Creating Application Inference Profiles (AIPs) per BU..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# `|| AIP_RC=$?` is required. deploy.sh runs under `set -e`, and create-aips.sh now exits
# non-zero when it cannot safely reconcile profiles. Without this the whole deploy would
# abort here and the diagnostic banner below — the entire point of detecting this — would
# never print.
AIP_RC=0
AIP_OUTPUT=$(bash scripts/create-aips.sh "$REGION" 2>&1) || AIP_RC=$?
echo "$AIP_OUTPUT" | grep -v "^---" || true
if [ "$AIP_RC" != "0" ]; then
    echo "  ⚠️  create-aips.sh exited ${AIP_RC} — see its output above."
fi

# Extract AIP ARNs from create-aips.sh stdout.
#
# Key matching is deliberately tolerant of both naming conventions. create-aips.sh now
# emits uppercase, underscored keys (AIP_ARCHITECTURE=, AIP_IT_OPERATIONS=), but it
# previously emitted the profile name verbatim (AIP_architecture=, AIP_it-operations=).
# A case-insensitive grep alone does not bridge the two, because the dash and the
# underscore differ — which is how the IT-Operations ARN silently resolved to empty and
# the team config table was never created. Normalising both sides removes that class of
# bug regardless of which version of the script runs.
#
# Stripping whitespace matters just as much: a stray space reaches Bedrock as an invalid
# model identifier, and the error names the ARN rather than the whitespace, so the cause
# is very easy to miss.
extract_aip() {
    local want
    want="$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')"
    printf '%s\n' "$AIP_OUTPUT" \
        | awk -F= -v want="$want" '
            /^AIP_/ {
                key = $1
                gsub(/-/, "_", key)
                if (toupper(key) == want) { sub(/^[^=]*=/, ""); print; exit }
            }' \
        | tr -d '[:space:]'
}

AIP_ARCHITECTURE=$(extract_aip AIP_ARCHITECTURE)
AIP_IT_OPERATIONS=$(extract_aip AIP_IT_OPERATIONS)

# Dashboard widgets are no longer templated on these two ids — Step 14 generates the
# per-BU widgets from .aip-map.json, which covers every (team, model) profile. These
# variables remain only for the human-readable summary below.

# On extraction failure: report it prominently and continue, but record it so the
# deployment summary cannot end on a success note. The rest of the deploy is still
# useful, and aborting here would leave a half-built environment — but a key mismatch
# previously produced a single easily-missed warning, which is how the team config table
# came to be absent without anyone noticing.
# Note this checks only the two original business units, because those are the two the
# human-readable summary prints. It is a smoke test of the create-aips.sh stdout contract,
# not the authoritative validation — create-team-config-table.sh compares every business
# unit in config/bu-models.json against .aip-map.json and fails if any is unresolved, which
# is what actually catches a third BU being added.
AIP_EXTRACTION_FAILED=""
if [ -z "$AIP_ARCHITECTURE" ] || [ -z "$AIP_IT_OPERATIONS" ]; then
    AIP_EXTRACTION_FAILED="yes"
    echo ""
    echo "  ════════════════════════════════════════════════════════════════"
    echo "  ⚠️  COULD NOT EXTRACT AIP ARNs — BU COST ATTRIBUTION WILL NOT WORK"
    echo "  ════════════════════════════════════════════════════════════════"
    echo "     Architecture:  ${AIP_ARCHITECTURE:-<empty>}"
    echo "     IT-Operations: ${AIP_IT_OPERATIONS:-<empty>}"
    echo ""
    echo "     The team config table will NOT be seeded, so every invocation will"
    echo "     run unattributed and the per-BU dashboard widgets will stay empty."
    echo ""
    echo "     create-aips.sh output was:"
    echo "$AIP_OUTPUT" | sed 's/^/       /'
    echo ""
    echo "     Fix with: ./scripts/create-aips.sh $REGION"
    echo "               ./scripts/create-team-config-table.sh $REGION"
    echo "  ════════════════════════════════════════════════════════════════"
    echo ""
else
    echo "  ✅ AIPs ready"
    echo "     Architecture:  ${AIP_ARCHITECTURE}"
    echo "     IT-Operations: ${AIP_IT_OPERATIONS}"

    # Create DynamoDB team config table and seed with AIP ARNs
    echo ""
    echo "  Creating team config table and seeding..."
    # Same reason as create-aips.sh above: the seeder exits non-zero when a business unit
    # in the matrix has no profile for its default model, and under `set -e` that would
    # abort the deploy instead of reporting it.
    SEED_RC=0
    bash scripts/create-team-config-table.sh "$REGION" || SEED_RC=$?
    if [ "$SEED_RC" != "0" ]; then
        AIP_EXTRACTION_FAILED="yes"
        echo ""
        echo "  ⚠️  Seeding the team config table failed (exit ${SEED_RC})."
        echo "     Business units without a row run UNATTRIBUTED. See the output above."
    fi
fi

echo ""

###############################################################################
# Step 4: Deploy custom Lambda tools CloudFormation stack
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 4: Deploying custom Lambda tools stack..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

deploy_stack "$CUSTOM_LAMBDAS_STACK" "custom-lambdas/template.yaml" \
  --parameters "ParameterKey=Stage,ParameterValue=${STAGE}" \
               "ParameterKey=CompanyName,ParameterValue=${COMPANY_NAME}"

# Get Lambda ARNs from stack outputs
SEARCH_KB_ARN=$(aws cloudformation describe-stacks --stack-name "$CUSTOM_LAMBDAS_STACK" \
  --query 'Stacks[0].Outputs[?OutputKey==`SearchKBLambdaArn`].OutputValue' \
  --output text --region "$REGION")

CREATE_TICKET_ARN=$(aws cloudformation describe-stacks --stack-name "$CUSTOM_LAMBDAS_STACK" \
  --query 'Stacks[0].Outputs[?OutputKey==`CreateTicketLambdaArn`].OutputValue' \
  --output text --region "$REGION")

echo "  ✅ Custom Lambda tools deployed"
echo "     search_kb ARN:      ${SEARCH_KB_ARN}"
echo "     create_ticket ARN:  ${CREATE_TICKET_ARN}"
echo ""

###############################################################################
# Step 5: Register MCP tools in AgentCore Gateway
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 5: Registering MCP tools in AgentCore Gateway..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# AgentCore Gateway uses the bedrock-agentcore-control service (present in recent
# AWS CLI v2 builds). Probe with list-gateways before attempting registration.
if aws bedrock-agentcore-control list-gateways --region "$REGION" --max-results 1 >/dev/null 2>&1; then
  bash scripts/register-tools.sh \
    "${COMPANY_NAME}-ai-gateway-${STAGE}" \
    "$SEARCH_KB_ARN" \
    "$CREATE_TICKET_ARN" \
    "$USER_POOL_ID" && echo "  ✅ MCP tools registered" || {
    echo "  ⚠️  MCP tool registration encountered an error (may already exist)"
    echo "     Run manually later: bash scripts/register-tools.sh ${COMPANY_NAME}-ai-gateway-${STAGE} \\"
    echo "       $SEARCH_KB_ARN $CREATE_TICKET_ARN $USER_POOL_ID"
  }
else
  echo "  ⚠️  AgentCore (bedrock-agentcore-control) not available in ${REGION} — skipping MCP registration"
  echo "     Run manually later: bash scripts/register-tools.sh ${COMPANY_NAME}-ai-gateway-${STAGE} \\"
  echo "       \$SEARCH_KB_ARN \$CREATE_TICKET_ARN $USER_POOL_ID"
fi

echo ""

###############################################################################
# Step 5a: AgentCore Identity (workload identity + token vault)
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 5a: Setting up AgentCore Identity (token vault)..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ -f ".agentcore-config.json" ]; then
  python3 scripts/setup-agentcore-identity.py --region "$REGION" && \
    echo "  ✅ AgentCore Identity configured" || {
    echo "  ⚠️  AgentCore Identity setup failed (non-blocking)"
    echo "     Run manually: python3 scripts/setup-agentcore-identity.py --region $REGION"
  }
else
  echo "  ⏭️  Skipping — .agentcore-config.json not found (gateway not registered)"
fi

echo ""

###############################################################################
# Step 5b: AgentCore Memory (cross-session persistence)
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 5b: Setting up AgentCore Memory..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ -f ".agentcore-config.json" ]; then
  python3 scripts/setup-agentcore-memory.py --region "$REGION" && \
    echo "  ✅ AgentCore Memory configured" || {
    echo "  ⚠️  AgentCore Memory setup failed (non-blocking)"
    echo "     Run manually: python3 scripts/setup-agentcore-memory.py --region $REGION"
  }
else
  echo "  ⏭️  Skipping — .agentcore-config.json not found (gateway not registered)"
fi

echo ""

###############################################################################
# Step 6: Configure usage plans
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 6: Configuring usage plans and rate limiting..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

EXISTING_PLAN=$(aws apigateway get-usage-plans \
  --query 'items[?name==`IT-Operations-Plan`].id' \
  --output text --region "$REGION" 2>/dev/null || echo "")

if [ -n "$EXISTING_PLAN" ] && [ "$EXISTING_PLAN" != "None" ]; then
  # Plan exists — but verify the current API stage is attached.
  # After a fresh deploy the API Gateway ID changes; the old stage association
  # becomes stale and keys stop working (requests return 403).
  CURRENT_API_ID=$(aws cloudformation describe-stacks \
    --stack-name "$GATEWAY_STACK" \
    --query 'Stacks[0].Outputs[?OutputKey==`ApiId`].OutputValue' \
    --output text --region "$REGION" 2>/dev/null || echo "")

  ATTACHED=$(aws apigateway get-usage-plan \
    --usage-plan-id "$EXISTING_PLAN" \
    --query "apiStages[?apiId=='${CURRENT_API_ID}'].apiId" \
    --output text --region "$REGION" 2>/dev/null || echo "")

  if [ -n "$ATTACHED" ] && [ "$ATTACHED" != "None" ]; then
    echo "  ⏭️  Usage plan 'IT-Operations-Plan' already exists and stage is attached — skipping"
  else
    echo "  ⚠️  Usage plan exists but current API stage not attached — patching..."
    aws apigateway update-usage-plan \
      --usage-plan-id "$EXISTING_PLAN" \
      --patch-operations "op=add,path=/apiStages,value=${CURRENT_API_ID}:v1" \
      --region "$REGION" >/dev/null 2>&1
    echo "  ✅ API stage ${CURRENT_API_ID}:v1 attached to usage plan"
  fi
else
  bash scripts/configure-usage-plans.sh \
    "$GATEWAY_STACK" \
    "config/usage-plans.json"
  echo "  ✅ Usage plans configured"
fi

# Retrieve API key value for config.js (needed by Client UI for usage plan tracking)
API_KEY_VALUE=$(aws apigateway get-api-keys --include-values \
  --query "items[?name=='IT-Operations-key'].value" \
  --output text --region "$REGION" 2>/dev/null || echo "")

echo ""

###############################################################################
# Step 7: Deploy frontend stack
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 7: Deploying frontend infrastructure (S3 + CloudFront)..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

deploy_stack "$FRONTEND_STACK" "cloudformation/frontend-stack.yaml"

# Get frontend outputs
FRONTEND_BUCKET=$(aws cloudformation describe-stacks --stack-name "$FRONTEND_STACK" \
  --query 'Stacks[0].Outputs[?OutputKey==`BucketName`].OutputValue' \
  --output text --region "$REGION")

CLOUDFRONT_URL=$(aws cloudformation describe-stacks --stack-name "$FRONTEND_STACK" \
  --query 'Stacks[0].Outputs[?OutputKey==`CloudFrontURL`].OutputValue' \
  --output text --region "$REGION")

DISTRIBUTION_ID=$(aws cloudformation describe-stacks --stack-name "$FRONTEND_STACK" \
  --query 'Stacks[0].Outputs[?OutputKey==`CloudFrontDistributionId`].OutputValue' \
  --output text --region "$REGION")

echo "  ✅ Frontend infrastructure deployed"
echo "     CloudFront URL: ${CLOUDFRONT_URL}"
echo ""

###############################################################################
# Step 8: Configure Cognito OAuth (Hosted UI, callback/logout URLs)
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 8: Configuring Cognito OAuth and Hosted UI..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Strip trailing slash from CloudFront URL if present and ensure https:// prefix
CF_DOMAIN="${CLOUDFRONT_URL%/}"
if [[ "$CF_DOMAIN" != https://* ]]; then
  CF_DOMAIN="https://${CF_DOMAIN}"
fi

# Check if callback URLs are already correctly configured
CURRENT_CALLBACKS=$(aws cognito-idp describe-user-pool-client \
  --user-pool-id "$USER_POOL_ID" \
  --client-id "$APP_CLIENT_ID" \
  --query 'UserPoolClient.CallbackURLs' \
  --output text --region "$REGION" 2>/dev/null || echo "")

if echo "$CURRENT_CALLBACKS" | grep -q "${CF_DOMAIN}/callback"; then
  echo "  ⏭️  Cognito OAuth already configured with correct callback URLs — skipping"
else
  bash scripts/configure-cognito-oauth.sh \
    --user-pool-id "$USER_POOL_ID" \
    --app-client-id "$APP_CLIENT_ID" \
    --cloudfront-domain "${CF_DOMAIN#https://}" \
    --region "$REGION"
  echo "  ✅ Cognito OAuth configured"
fi

echo ""

###############################################################################
# Step 9: Build and deploy Client UI
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 9: Building and deploying Client UI..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Always rebuild and sync — s3 sync with --delete is idempotent by nature

# frontend/public/config.js is a generated artifact, not source: it holds
# account-specific identifiers and an API key. It is gitignored for that reason —
# see frontend/public/config.example.js for the shape.
cat > frontend/public/config.js << EOF
// GENERATED by deploy.sh — do not edit or commit. Gitignored.
window.CONFIG = {
  COGNITO_DOMAIN: '${COGNITO_DOMAIN_URL}',
  COGNITO_CLIENT_ID: '${APP_CLIENT_ID}',
  COGNITO_REDIRECT_URI: '${CF_DOMAIN}/callback',
  COGNITO_LOGOUT_URI: '${CF_DOMAIN}',
  API_GATEWAY_URL: '${GATEWAY_URL}',
  API_KEY: '${API_KEY_VALUE}'
};
EOF

echo "  📝 config.js written with runtime values"

# Build frontend
cd frontend
echo "  📦 Installing dependencies..."
npm install --silent
echo "  🔨 Building production bundle..."
npm run build --silent
cd ..

# Upload to S3 (idempotent — sync with --delete)
echo "  ☁️  Uploading to S3..."
aws s3 sync frontend/build/ "s3://${FRONTEND_BUCKET}/" --delete --region "$REGION" --quiet

# Invalidate CloudFront cache
echo "  🔄 Invalidating CloudFront cache..."
aws cloudfront create-invalidation \
  --distribution-id "$DISTRIBUTION_ID" \
  --paths "/*" \
  --output text --quiet >/dev/null 2>&1 || true

echo "  ✅ Client UI deployed"
echo ""

###############################################################################
# Step 10: Configure CORS on API Gateway
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 10: Configuring CORS on API Gateway..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Always apply — put-gateway-response is idempotent (overwrites existing)
aws apigateway put-gateway-response \
  --rest-api-id "$API_ID" \
  --response-type DEFAULT_4XX \
  --response-parameters '{"gatewayresponse.header.Access-Control-Allow-Origin":"'"'${CF_DOMAIN}'"'","gatewayresponse.header.Access-Control-Allow-Headers":"'"'Content-Type,Authorization,X-Api-Key'"'","gatewayresponse.header.Access-Control-Allow-Methods":"'"'POST,OPTIONS'"'"}' \
  --region "$REGION" >/dev/null

aws apigateway put-gateway-response \
  --rest-api-id "$API_ID" \
  --response-type DEFAULT_5XX \
  --response-parameters '{"gatewayresponse.header.Access-Control-Allow-Origin":"'"'${CF_DOMAIN}'"'","gatewayresponse.header.Access-Control-Allow-Headers":"'"'Content-Type,Authorization,X-Api-Key'"'","gatewayresponse.header.Access-Control-Allow-Methods":"'"'POST,OPTIONS'"'"}' \
  --region "$REGION" >/dev/null

# Redeploy API to apply changes
aws apigateway create-deployment \
  --rest-api-id "$API_ID" \
  --stage-name "v1" \
  --region "$REGION" >/dev/null 2>&1 || true

echo "  ✅ CORS configured with allowed origin: ${CF_DOMAIN}"
echo ""

###############################################################################
# Step 11: Create Cognito users
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 11: Creating Cognito users..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Prompt once for the temporary password used for all new Cognito users.
# Cognito forces a password change on first login via the Hosted UI — this
# temporary password is never reused after that point.
if [ -z "$COGNITO_TEMP_PASSWORD" ]; then
  read -rsp "  Enter temporary password for new Cognito users: " COGNITO_TEMP_PASSWORD
  echo ""
fi
if [ -z "$COGNITO_TEMP_PASSWORD" ]; then
  echo "❌ ERROR: temporary password cannot be empty"
  exit 1
fi

USER_EMAIL="$ALERT_EMAIL"

if aws cognito-idp admin-get-user \
  --user-pool-id "$USER_POOL_ID" \
  --username "$USER_EMAIL" \
  --region "$REGION" >/dev/null 2>&1; then
  echo "  ⏭️  User '${USER_EMAIL}' already exists — skipping"
else
  python3 scripts/create-cognito-users.py \
    "$USER_POOL_ID" \
    "$USER_EMAIL" \
    --temp-password "$COGNITO_TEMP_PASSWORD" \
    --team "Architecture" \
    --role "admin" \
    --region "$REGION"
  echo "  ✅ Admin user created: ${USER_EMAIL}"
fi

# Create IT-Operations demo user for BU cost attribution testing
ITOPS_EMAIL="demo-itops@example.com"
if aws cognito-idp admin-get-user \
  --user-pool-id "$USER_POOL_ID" \
  --username "$ITOPS_EMAIL" \
  --region "$REGION" >/dev/null 2>&1; then
  echo "  ⏭️  IT-Operations demo user already exists — skipping"
else
  python3 scripts/create-cognito-users.py \
    "$USER_POOL_ID" \
    "$ITOPS_EMAIL" \
    --temp-password "$COGNITO_TEMP_PASSWORD" \
    --team "IT-Operations" \
    --role "admin" \
    --region "$REGION"
  echo "  ✅ IT-Operations demo user created: ${ITOPS_EMAIL}"
fi

echo ""

###############################################################################
# Step 12: Deploy demo agent
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 12: Deploying demo Strands agent..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Requires: gateway registered (.agentcore-config.json) + Docker for ARM64 build +
# the bedrock-agentcore-control service. Each gate degrades gracefully.
if [ ! -f ".agentcore-config.json" ]; then
  echo "  ⚠️  .agentcore-config.json not found — gateway not registered. Skipping demo agent."
  echo "     Run Step 4 (register-tools.sh) first, then: bash scripts/deploy-demo-agent.sh"
elif ! { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; } && \
     ! { command -v finch >/dev/null 2>&1 && finch info >/dev/null 2>&1; }; then
  echo "  ⚠️  Docker/Finch not available/running — cannot build the ARM64 agent image. Skipping demo agent."
  echo "     Start Docker or Finch, then run: bash scripts/deploy-demo-agent.sh"
elif ! aws bedrock-agentcore-control list-agent-runtimes --region "$REGION" --max-results 1 >/dev/null 2>&1; then
  echo "  ⚠️  AgentCore Runtime (bedrock-agentcore-control) not available in ${REGION} — skipping demo agent"
  echo "     Run manually later: bash scripts/deploy-demo-agent.sh"
else
  bash scripts/deploy-demo-agent.sh \
    "${COMPANY_NAME}-ai-gateway-${STAGE}" \
    --company-name "$COMPANY_NAME" \
    --stage "$STAGE" && echo "  ✅ Demo agent deployed" || {
    echo "  ⚠️  Demo agent deployment encountered an error"
    echo "     Run manually later: bash scripts/deploy-demo-agent.sh"
  }
fi

echo ""

###############################################################################
# Step 12a: Agent Registry (publish MCP + A2A records for discovery)
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 12a: Publishing to Agent Registry..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ -f ".agentcore-config.json" ]; then
  python3 scripts/setup-agent-registry.py --region "$REGION" && \
    echo "  ✅ Agent Registry populated" || {
    echo "  ⚠️  Agent Registry setup failed (non-blocking)"
    echo "     Run manually: python3 scripts/setup-agent-registry.py --region $REGION"
  }
else
  echo "  ⏭️  Skipping — .agentcore-config.json not found"
fi

echo ""

###############################################################################
# Step 13: Create budget alert
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 13: Creating budget alert..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if aws budgets describe-budget \
  --account-id "$(aws sts get-caller-identity --query Account --output text)" \
  --budget-name "${COMPANY_NAME}-ai-gateway-${STAGE}" \
  --region "$REGION" >/dev/null 2>&1; then
  echo "  ⏭️  Budget '${COMPANY_NAME}-ai-gateway-${STAGE}' already exists — skipping"
else
  python3 scripts/create-budget-alert.py \
    "$ALERT_EMAIL" \
    --budget-name "${COMPANY_NAME}-ai-gateway-${STAGE}" \
    --region "$REGION" \
  && echo "  ✅ Budget alert created ($500/month threshold, alert at 80%)" || \
     echo "  ⚠️  Budget alert creation failed (non-blocking) — check IAM permissions or create manually"
fi

echo ""

###############################################################################
# Step 14: Deploy CloudWatch dashboard
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 14: Deploying CloudWatch dashboard..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

DASHBOARD_NAME="${COMPANY_NAME}-ai-gateway-${STAGE}"

# The per-business-unit widgets are generated rather than templated. A business unit
# using several models has one inference profile per model, so the set of profile ids
# is only known after Step 3 reconciled config/bu-models.json. update-dashboard.py
# reads .aip-map.json, builds those widgets (including per-model cost math), and
# deploys. It always runs, so adding a model or a BU is picked up on redeploy.
if python3 scripts/update-dashboard.py --region "$REGION" --stage "$STAGE" --company-name "$COMPANY_NAME"; then
  echo "  ✅ CloudWatch dashboard deployed: ${DASHBOARD_NAME}"
else
  echo "  ⚠️  Dashboard deploy failed — check that scripts/create-aips.sh ran (needs .aip-map.json)"
fi

echo ""

###############################################################################
# Step 15: Create dedicated test App Client (for automated test scripts)
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 15: Creating test App Client for automated tests..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# The test client enables ADMIN_USER_PASSWORD_AUTH for scripted token acquisition.
# Production client remains OAuth2/PKCE only (hardened).
TEST_CLIENT_OUTPUT=$(bash scripts/create-test-client.sh "$USER_POOL_ID" "$REGION" "" "${COMPANY_NAME}-${STAGE}-test-client")
TEST_CLIENT_ID=$(echo "$TEST_CLIENT_OUTPUT" | grep "^TEST_CLIENT_ID=" | cut -d= -f2)

echo "  ✅ Test client ready: ${TEST_CLIENT_ID}"
echo ""

###############################################################################
# Deployment Summary + auto-write .env.md
###############################################################################

# Turn off -e for the summary section so a single AWS lookup failure
# (e.g. missing permissions) never prevents .env.md from being written.
set +e

# Resolve any values not yet in scope
COGNITO_DOMAIN_BARE=$(echo "$COGNITO_DOMAIN_URL" | sed 's|https://||' | sed 's|\.auth\..*||')
API_KEY_DISPLAY=$(aws apigateway get-api-keys --include-values --region "$REGION" \
  --query "items[?name=='IT-Operations-key'].value | [0]" --output text 2>/dev/null || echo "")

# Write .env.md with all current deployment values so tests and agentic tools
# never need to go back to the AWS console to find IDs.
cat > .env.md << ENVEOF
# AI Gateway POC — Environment Details

> ⚠️ DO NOT COMMIT THIS FILE — it contains credentials

## Deployed Endpoints

| Resource | URL |
|----------|-----|
| Client UI | ${CF_DOMAIN} |
| API Gateway | ${GATEWAY_URL} |
| Cognito Login | ${COGNITO_DOMAIN_URL}/login?client_id=${APP_CLIENT_ID}&response_type=code&scope=openid+profile+email&redirect_uri=${CF_DOMAIN}/callback |

## Login Credentials

| Field | Value |
|-------|-------|
| Username | ${USER_EMAIL} |
| Team | Architecture |
| Temporary Password | ${COGNITO_TEMP_PASSWORD} |
| New Password (set on first login) | (set by user on first login) |

> Password must meet Cognito requirements: 8+ chars, uppercase, lowercase, number, symbol

### Second test user (IT-Operations team)

Used to drive traffic through the IT-Operations AIP for cost/token attribution testing.

| Field | Value |
|-------|-------|
| Username | demo-itops@example.com |
| Team | IT-Operations |
| Password | (set same as admin on first deploy) |

## AWS Resources

| Resource | ID |
|----------|-----|
| AWS Account | $(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "unknown") |
| AWS Profile | ${PROFILE:-<default credential chain>} |
| Region | ${REGION} |
| Cognito User Pool ID | ${USER_POOL_ID} |
| Cognito App Client ID | ${APP_CLIENT_ID} |
| Cognito Domain | ${COGNITO_DOMAIN_BARE} |
| API Gateway URL | ${GATEWAY_URL} |
| API Gateway ID | $(echo "${GATEWAY_URL}" | sed 's|https://||' | cut -d. -f1) |
| CloudFront URL | ${CF_DOMAIN} |
| CloudFront Distribution ID | ${DISTRIBUTION_ID} |
| S3 Frontend Bucket | $(aws cloudformation describe-stacks --stack-name "$FRONTEND_STACK" --region "$REGION" --query 'Stacks[0].Outputs[?OutputKey==\`BucketName\`].OutputValue' --output text 2>/dev/null || echo "see CF stack") |
| Test App Client | ${TEST_CLIENT_ID} |
| IT-Operations API Key | ${API_KEY_DISPLAY} |

## Phase 2 Resources (populated after deploy-phase2.sh)

| Resource | ID |
|----------|-----|
| Knowledge Base ID | (run deploy-phase2.sh) |
| KB Data Source ID | (run deploy-phase2.sh) |
| S3 KB Docs Bucket | -kb-docs-$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "ACCOUNT_ID") |

## CloudFormation Stacks

| Stack Name | Status |
|------------|--------|
| ${COMPANY_NAME}-ai-gateway-${STAGE} | ✅ DEPLOYED |
| ${COMPANY_NAME}-mcp-tools-${STAGE} | ✅ DEPLOYED |
| ${COMPANY_NAME}-frontend-${STAGE} | ✅ DEPLOYED |

## Test Infrastructure

| Resource | ID | Notes |
|----------|-----|-------|
| Test App Client | \`${TEST_CLIENT_ID}\` | Created via \`./scripts/create-test-client.sh\` |
| IT-Operations API Key | \`${API_KEY_DISPLAY}\` | Required for rate-limiting tests |

## Run All Tests

\`\`\`bash
export AWS_PROFILE=${AWS_PROFILE:-}
export COGNITO_USERNAME="${USER_EMAIL}"
export COGNITO_PASSWORD='<YOUR_NEW_PASSWORD>'
./tests/run-all-tests.sh
\`\`\`

> ⚠️  Set COGNITO_PASSWORD to the password you set on first login (not the temporary password you passed to deploy.sh).
> Run deploy-phase2.sh first or search_kb tests will fail.
ENVEOF

chmod 600 .env.md
echo "  ✅ .env.md written with all deployment values"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                                                            ║"
if [ -n "${AIP_EXTRACTION_FAILED:-}" ]; then
echo "║   ⚠️  POC Deployed — BUT COST ATTRIBUTION IS NOT WORKING    ║"
else
echo "║   ✅ POC Deployment Complete!                              ║"
fi
echo "║                                                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "   Gateway URL:          ${GATEWAY_URL}"
echo "   Client UI:            ${CF_DOMAIN}"
echo "   Cognito Login URL:    ${COGNITO_DOMAIN_URL}/login?client_id=${APP_CLIENT_ID}&response_type=code&scope=openid+profile+email&redirect_uri=${CF_DOMAIN}/callback"
echo ""
echo "   AWS Resource IDs (also written to .env.md):"
echo "     User Pool ID:        ${USER_POOL_ID}"
echo "     App Client ID:       ${APP_CLIENT_ID}  (OAuth2/PKCE — production)"
echo "     Test App Client:     ${TEST_CLIENT_ID}  (ADMIN_NO_SRP_AUTH — tests only)"
echo "     CloudFront Dist ID:  ${DISTRIBUTION_ID}"
echo "     IT-Operations Key:   ${API_KEY_DISPLAY}"
echo ""
echo "   Test User:"
echo "     Username:            ${USER_EMAIL}"
echo "     Temp Password:       ${COGNITO_TEMP_PASSWORD}  ← change on first login"
echo "     Second test user:    demo-itops@example.com (IT-Operations team)"
echo "       Set its password:  aws cognito-idp admin-set-user-password \\"
echo "         --user-pool-id ${USER_POOL_ID} --username demo-itops@example.com \\"
echo "         --password '<PASSWORD>' --permanent --region ${REGION}"
echo ""
echo "   Next Steps:"
echo "     1. Open the Cognito Login URL above in your browser"
echo "     2. Sign in with ${COGNITO_TEMP_PASSWORD} and set a permanent password"
echo "     3. Set the IT-Operations test user password (command above)"
echo "     4. Wait 10-15 min then run deploy-phase2.sh (see Step 16 below)"
echo ""
echo "   Run tests (after completing Next Steps):"
echo "     export COGNITO_USERNAME=\"${USER_EMAIL}\""
echo "     export COGNITO_PASSWORD='<YOUR_NEW_PASSWORD>'"
echo "     export AWS_PROFILE=${AWS_PROFILE:-}"
echo "     ./tests/run-all-tests.sh"
echo ""
echo "   CloudWatch Dashboard:"
echo "     Open AWS Console → CloudWatch → Dashboards → ${COMPANY_NAME}-ai-gateway-${STAGE}"
echo ""

###############################################################################
# Step 16: Prompt for Phase 2 (Knowledge Base setup)
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 16: Phase 2 — Knowledge Base (run after OpenSearch is ACTIVE)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  The OpenSearch collection takes 10-15 min to become ACTIVE."
echo "  Run these checks, then run deploy-phase2.sh:"
echo ""
echo "  1. Check OpenSearch collection status (wait for ACTIVE):"
echo "       aws opensearchserverless batch-get-collection \\"
echo "         --names ${COMPANY_NAME}-kb-${STAGE} --region ${REGION} \\"
echo "         --query 'collectionDetails[0].status' --output text"
echo ""
echo "  2. Run Phase 2:"
echo "       bash deploy-phase2.sh --region ${REGION} --stage ${STAGE}"
echo ""
echo "  ⚠️  Tests will fail on search_kb until Phase 2 is complete."
echo ""
