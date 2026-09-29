#!/bin/bash
# Configure API Gateway Usage Plans for rate limiting
# Usage: ./scripts/configure-usage-plans.sh <stack-name> <config-file>

set -e

STACK_NAME="${1:?Usage: $0 <stack-name> <config-file>}"
CONFIG_FILE="${2:?Usage: $0 <stack-name> <config-file>}"

echo "  ⚡ Configuring usage plans..."
echo "     Stack: $STACK_NAME"
echo "     Config: $CONFIG_FILE"

# Validate config file exists
if [ ! -f "$CONFIG_FILE" ]; then
  echo "  ❌ Config file not found: $CONFIG_FILE"
  exit 1
fi

# Get API Gateway ID from CloudFormation stack outputs
API_ID=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs[?OutputKey==`ApiId`].OutputValue' \
  --output text)

if [ -z "$API_ID" ] || [ "$API_ID" = "None" ]; then
  echo "  ❌ Could not find API Gateway ID (OutputKey: ApiId) from stack: $STACK_NAME"
  exit 1
fi

echo "     API Gateway ID: $API_ID"

# Get stage name from CloudFormation stack outputs
STAGE_NAME=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs[?OutputKey==`StageName`].OutputValue' \
  --output text)

if [ -z "$STAGE_NAME" ] || [ "$STAGE_NAME" = "None" ]; then
  echo "  ℹ️  StageName output not found, defaulting to 'v1'"
  STAGE_NAME="v1"
fi

echo "     Stage Name: $STAGE_NAME"

# Read usage plan configuration from JSON file
PLAN_NAME=$(jq -r '.usagePlan.name' "$CONFIG_FILE")
PLAN_DESC=$(jq -r '.usagePlan.description // "AI Gateway usage plan"' "$CONFIG_FILE")
RATE_LIMIT=$(jq -r '.usagePlan.throttle.rateLimit' "$CONFIG_FILE")
BURST_LIMIT=$(jq -r '.usagePlan.throttle.burstLimit' "$CONFIG_FILE")
QUOTA_LIMIT=$(jq -r '.usagePlan.quota.limit' "$CONFIG_FILE")
QUOTA_PERIOD=$(jq -r '.usagePlan.quota.period' "$CONFIG_FILE")

echo "  📋 Usage Plan: $PLAN_NAME"
echo "     Rate Limit: $RATE_LIMIT req/s | Burst: $BURST_LIMIT req/s"
echo "     Quota: $QUOTA_LIMIT per $QUOTA_PERIOD"

# Create usage plan with throttle and quota settings
PLAN_ID=$(aws apigateway create-usage-plan \
  --name "$PLAN_NAME" \
  --description "$PLAN_DESC" \
  --throttle "rateLimit=$RATE_LIMIT,burstLimit=$BURST_LIMIT" \
  --quota "limit=$QUOTA_LIMIT,period=$QUOTA_PERIOD" \
  --api-stages "apiId=$API_ID,stage=$STAGE_NAME" \
  --query 'id' \
  --output text)

if [ -z "$PLAN_ID" ] || [ "$PLAN_ID" = "None" ]; then
  echo "  ❌ Failed to create usage plan"
  exit 1
fi

echo "  ✅ Usage Plan created: $PLAN_ID"

# Create API key(s) and associate with usage plan
for KEY_NAME in $(jq -r '.apiKeys[].name' "$CONFIG_FILE"); do
  KEY_DESC=$(jq -r ".apiKeys[] | select(.name==\"$KEY_NAME\") | .description" "$CONFIG_FILE")

  echo "  🔑 Creating API key: $KEY_NAME"

  # Create API key
  KEY_RESPONSE=$(aws apigateway create-api-key \
    --name "$KEY_NAME" \
    --description "$KEY_DESC" \
    --enabled \
    --output json)

  KEY_ID=$(echo "$KEY_RESPONSE" | jq -r '.id')
  KEY_VALUE=$(echo "$KEY_RESPONSE" | jq -r '.value')

  if [ -z "$KEY_ID" ] || [ "$KEY_ID" = "null" ]; then
    echo "  ❌ Failed to create API key: $KEY_NAME"
    exit 1
  fi

  # Associate API key with usage plan
  aws apigateway create-usage-plan-key \
    --usage-plan-id "$PLAN_ID" \
    --key-id "$KEY_ID" \
    --key-type "API_KEY" \
    --output text > /dev/null

  echo "  ✅ API key '$KEY_NAME' associated with usage plan"
  echo ""
  echo "  =========================================="
  echo "  API Key Value (save this for testing):"
  echo "  $KEY_VALUE"
  echo "  =========================================="
done

echo ""
echo "  ✅ Usage plans configured successfully"
