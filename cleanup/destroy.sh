#!/bin/bash

# AI Gateway POC — Cleanup / Destroy Script
# Usage: ./cleanup/destroy.sh --region <aws-region> [--stage poc]
#
# Deletes all POC resources in reverse dependency order.
# Continues on individual failures and reports all at end.

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   AI Gateway POC — Cleanup Script                           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

###############################################################################
# Parse arguments
###############################################################################
REGION=""
STAGE="poc"
COMPANY_NAME="anycompany"
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
    --profile)
      PROFILE="$2"
      shift 2
      ;;
    *)
      echo "❌ Unknown parameter: $1"
      echo "Usage: ./cleanup/destroy.sh --region <aws-region> [--stage poc] [--company-name anycompany] [--profile <aws-profile>]"
      exit 1
      ;;
  esac
done

if [ -z "$REGION" ]; then
  echo "❌ ERROR: --region is required"
  echo "Usage: ./cleanup/destroy.sh --region <aws-region> [--stage poc] [--company-name anycompany] [--profile <aws-profile>]"
  exit 1
fi

# Resolve project paths (used by Step 2b and Step 7)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

export AWS_REGION="$REGION"
export AWS_DEFAULT_REGION="$REGION"
[ -n "$PROFILE" ] && export AWS_PROFILE="$PROFILE"

# Stack names (must match deploy.sh)
GATEWAY_STACK="${COMPANY_NAME}-ai-gateway-${STAGE}"
CUSTOM_LAMBDAS_STACK="${COMPANY_NAME}-mcp-tools-${STAGE}"
FRONTEND_STACK="${COMPANY_NAME}-frontend-${STAGE}"

FAILURES=()

echo "Configuration:"
echo "  Region: $REGION"
echo "  Stage:  $STAGE"
echo ""
echo "⚠️  This will permanently delete ALL POC resources."
read -rp "Are you sure? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Aborted."
  exit 0
fi
echo ""

###############################################################################
# Helper: record failure and continue
###############################################################################
record_failure() {
  FAILURES+=("$1")
  echo "  ⚠️  FAILED: $1"
}

###############################################################################
# Step 1: Disable and delete CloudFront distribution
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 1: Disabling CloudFront distribution..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

DISTRIBUTION_ID=""
if aws cloudformation describe-stacks --stack-name "$FRONTEND_STACK" --region "$REGION" >/dev/null 2>&1; then
  DISTRIBUTION_ID=$(aws cloudformation describe-stacks --stack-name "$FRONTEND_STACK" \
    --query 'Stacks[0].Outputs[?OutputKey==`CloudFrontDistributionId`].OutputValue' \
    --output text --region "$REGION" 2>/dev/null || true)
fi

if [ -n "$DISTRIBUTION_ID" ] && [ "$DISTRIBUTION_ID" != "None" ]; then
  echo "  Found distribution: ${DISTRIBUTION_ID}"

  # Get current config and ETag
  DIST_CONFIG=$(aws cloudfront get-distribution-config \
    --id "$DISTRIBUTION_ID" 2>/dev/null || true)

  if [ -n "$DIST_CONFIG" ]; then
    ETAG=$(echo "$DIST_CONFIG" | jq -r '.ETag')
    IS_ENABLED=$(echo "$DIST_CONFIG" | jq -r '.DistributionConfig.Enabled')

    if [ "$IS_ENABLED" = "true" ]; then
      echo "  Disabling distribution (this may take several minutes)..."
      # Extract DistributionConfig and set Enabled=false
      UPDATED_CONFIG=$(echo "$DIST_CONFIG" | jq '.DistributionConfig.Enabled = false | .DistributionConfig')

      aws cloudfront update-distribution \
        --id "$DISTRIBUTION_ID" \
        --distribution-config "$UPDATED_CONFIG" \
        --if-match "$ETAG" >/dev/null 2>&1

      if [ $? -eq 0 ]; then
        echo "  ⏳ Waiting for distribution to be disabled (this can take 5-15 minutes)..."
        aws cloudfront wait distribution-deployed --id "$DISTRIBUTION_ID" 2>/dev/null || true
        echo "  ✅ CloudFront distribution disabled"
      else
        record_failure "Disable CloudFront distribution ${DISTRIBUTION_ID}"
      fi
    else
      echo "  Distribution already disabled"
    fi
  fi
else
  echo "  No CloudFront distribution found, skipping"
fi
echo ""

###############################################################################
# Step 2: Empty and delete S3 buckets
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 2: Emptying and deleting S3 buckets..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)

# Client UI bucket (from frontend stack)
FRONTEND_BUCKET=""
if aws cloudformation describe-stacks --stack-name "$FRONTEND_STACK" --region "$REGION" >/dev/null 2>&1; then
  FRONTEND_BUCKET=$(aws cloudformation describe-stacks --stack-name "$FRONTEND_STACK" \
    --query 'Stacks[0].Outputs[?OutputKey==`BucketName`].OutputValue' \
    --output text --region "$REGION" 2>/dev/null || true)
fi

# KB source bucket (from custom lambdas stack)
KB_BUCKET=""
if aws cloudformation describe-stacks --stack-name "$CUSTOM_LAMBDAS_STACK" --region "$REGION" >/dev/null 2>&1; then
  KB_BUCKET=$(aws cloudformation describe-stacks --stack-name "$CUSTOM_LAMBDAS_STACK" \
    --query 'Stacks[0].Outputs[?OutputKey==`KBSourceBucketName`].OutputValue' \
    --output text --region "$REGION" 2>/dev/null || true)
fi

empty_bucket() {
  local bucket="$1"
  local label="$2"

  if [ -z "$bucket" ] || [ "$bucket" = "None" ]; then
    echo "  ⏭️  ${label}: bucket not found, skipping"
    return
  fi

  # Check bucket exists before attempting deletion.
  # Use 'aws ... && found=1 || found=0' pattern so set -e in the caller
  # doesn't abort on the non-zero exit from head-bucket for missing buckets.
  local found=1
  aws s3api head-bucket --bucket "$bucket" --region "$REGION" \
    2>/dev/null 1>/dev/null && found=1 || found=0
  if [ "$found" -eq 0 ]; then
    echo "  ⏭️  ${label} (${bucket}): already gone, skipping"
    return
  fi

  echo "  🗑️  Emptying ${label} (${bucket})..."

  # Use Python to purge all object versions and delete markers in one pass.
  # aws s3 rm and aws s3 rb --force only remove current-version objects.
  # Buckets with versioning enabled retain all versions and delete markers,
  # causing 'aws s3api delete-bucket' (and CloudFormation stack deletion)
  # to fail with BucketNotEmpty. This script handles all three cases:
  # non-versioned, versioned, and MFA-delete-disabled versioned buckets.
  python3 - "$bucket" "$REGION" << 'PYEOF'
import sys
import boto3
from botocore.exceptions import ClientError

bucket, region = sys.argv[1], sys.argv[2]
s3 = boto3.client('s3', region_name=region)

total = 0
paginator = s3.get_paginator('list_object_versions')
try:
    for page in paginator.paginate(Bucket=bucket):
        to_delete = []
        for v in page.get('Versions', []):
            to_delete.append({'Key': v['Key'], 'VersionId': v['VersionId']})
        for m in page.get('DeleteMarkers', []):
            to_delete.append({'Key': m['Key'], 'VersionId': m['VersionId']})
        if to_delete:
            s3.delete_objects(
                Bucket=bucket,
                Delete={'Objects': to_delete, 'Quiet': True}
            )
            total += len(to_delete)
except ClientError as e:
    code = e.response['Error']['Code']
    if code in ('NoSuchBucket', 'NoSuchKey'):
        pass  # already gone
    else:
        print(f'    Warning: {e}', file=sys.stderr)

if total:
    print(f'    Purged {total} version(s) and delete marker(s)')
PYEOF

  # Now delete the bucket itself (guaranteed empty at this point)
  if aws s3api delete-bucket --bucket "$bucket" --region "$REGION" 2>/dev/null; then
    echo "  ✅ ${label} (${bucket}) deleted"
  else
    record_failure "Empty/delete S3 bucket: ${bucket} (${label})"
  fi
}

empty_bucket "$FRONTEND_BUCKET" "Client UI bucket"
empty_bucket "$KB_BUCKET" "KB source bucket"

echo ""

###############################################################################
# Step 2b: Teardown AgentCore extras (identity, memory, registry)
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 2b: Removing AgentCore extras (identity, memory, registry)..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ -f "$PROJECT_ROOT/.agentcore-config.json" ]; then
  python3 "$PROJECT_ROOT/scripts/teardown-agentcore-extras.py" --region "$REGION" || \
    record_failure "Teardown AgentCore extras (identity/memory/registry)"
else
  echo "  ⏭️  No .agentcore-config.json — skipping"
fi

echo ""

###############################################################################
# Step 3: Remove AgentCore Gateway and registered tools
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 3: Removing AgentCore Gateway and tools..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

GATEWAY_NAME="${COMPANY_NAME}-ai-gateway-${STAGE}"
RUNTIME_NAME="${COMPANY_NAME}_${STAGE}_demo_agent"
ACC="aws bedrock-agentcore-control --region $REGION"

if ! $ACC list-gateways --max-results 1 >/dev/null 2>&1; then
  echo "  ⏭️  bedrock-agentcore-control not available in ${REGION} — skipping AgentCore teardown"
else
  # --- 3a: Delete the demo agent runtime (delete custom endpoints first) ---
  RUNTIME_ID="$($ACC list-agent-runtimes --max-results 100 \
    --query "agentRuntimes[?agentRuntimeName=='${RUNTIME_NAME}'].agentRuntimeId | [0]" \
    --output text 2>/dev/null || echo "None")"

  if [ -n "$RUNTIME_ID" ] && [ "$RUNTIME_ID" != "None" ]; then
    # Remove non-DEFAULT endpoints (DEFAULT cannot be deleted explicitly).
    for EP in $($ACC list-agent-runtime-endpoints --agent-runtime-id "$RUNTIME_ID" \
      --query "runtimeEndpoints[?name!='DEFAULT'].name" --output text 2>/dev/null); do
      $ACC delete-agent-runtime-endpoint --agent-runtime-id "$RUNTIME_ID" \
        --endpoint-name "$EP" 2>/dev/null \
        && echo "  ✅ Deleted runtime endpoint ${EP}" \
        || record_failure "Delete runtime endpoint: ${EP}"
    done

    if $ACC delete-agent-runtime --agent-runtime-id "$RUNTIME_ID" 2>/dev/null; then
      echo "  ✅ AgentCore Runtime '${RUNTIME_NAME}' deleted"
    else
      record_failure "Delete AgentCore Runtime: ${RUNTIME_NAME}"
    fi
  else
    echo "  ⏭️  No AgentCore Runtime '${RUNTIME_NAME}' found"
  fi

  # --- 3b: Delete the gateway (targets must be removed first) ---
  GATEWAY_ID="$($ACC list-gateways --max-results 100 \
    --query "items[?name=='${GATEWAY_NAME}'].gatewayId | [0]" \
    --output text 2>/dev/null || echo "None")"

  if [ -n "$GATEWAY_ID" ] && [ "$GATEWAY_ID" != "None" ]; then
    for TID in $($ACC list-gateway-targets --gateway-identifier "$GATEWAY_ID" \
      --max-results 100 --query 'items[].targetId' --output text 2>/dev/null); do
      $ACC delete-gateway-target --gateway-identifier "$GATEWAY_ID" --target-id "$TID" 2>/dev/null \
        && echo "  ✅ Deleted gateway target ${TID}" \
        || record_failure "Delete gateway target: ${TID}"
    done

    # Wait for targets to finish deleting before attempting gateway deletion.
    echo "  ⏳ Waiting 15s for gateway targets to finish deleting..."
    sleep 15

    if $ACC delete-gateway --gateway-identifier "$GATEWAY_ID" 2>/dev/null; then
      echo "  ✅ AgentCore Gateway '${GATEWAY_NAME}' (${GATEWAY_ID}) deleted"
    else
      record_failure "Delete AgentCore Gateway: ${GATEWAY_NAME}"
    fi
  else
    echo "  ⏭️  No AgentCore Gateway '${GATEWAY_NAME}' found"
  fi
fi

# --- 3c: Delete ECR repository for the demo agent image ---
if aws ecr describe-repositories --repository-names "${COMPANY_NAME}-${STAGE}-demo-agent" --region "$REGION" >/dev/null 2>&1; then
  aws ecr delete-repository --repository-name "${COMPANY_NAME}-${STAGE}-demo-agent" --force --region "$REGION" >/dev/null 2>&1 \
    && echo "  ✅ ECR repository '${COMPANY_NAME}-${STAGE}-demo-agent' deleted" \
    || record_failure "Delete ECR repository: ${COMPANY_NAME}-${STAGE}-demo-agent"
fi

# --- 3d: Delete supporting IAM roles ---
for ROLE in "${GATEWAY_NAME}-gateway-role" "${COMPANY_NAME}-${STAGE}-agent-runtime-role"; do
  if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
    for P in $(aws iam list-role-policies --role-name "$ROLE" --query 'PolicyNames' --output text 2>/dev/null); do
      aws iam delete-role-policy --role-name "$ROLE" --policy-name "$P" 2>/dev/null || true
    done
    aws iam delete-role --role-name "$ROLE" 2>/dev/null \
      && echo "  ✅ IAM role '${ROLE}' deleted" \
      || record_failure "Delete IAM role: ${ROLE}"
  fi
done

echo ""

###############################################################################
# Step 4: Delete Cognito User Pool domain
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 4: Deleting Cognito User Pool domain..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

USER_POOL_ID=""
if aws cloudformation describe-stacks --stack-name "$GATEWAY_STACK" --region "$REGION" >/dev/null 2>&1; then
  USER_POOL_ID=$(aws cloudformation describe-stacks --stack-name "$GATEWAY_STACK" \
    --query 'Stacks[0].Outputs[?OutputKey==`UserPoolId`].OutputValue' \
    --output text --region "$REGION" 2>/dev/null || true)
fi

if [ -n "$USER_POOL_ID" ] && [ "$USER_POOL_ID" != "None" ]; then
  # Read the actual domain from the User Pool rather than guessing the name.
  COGNITO_DOMAIN=$(aws cognito-idp describe-user-pool \
    --user-pool-id "$USER_POOL_ID" \
    --region "$REGION" \
    --query 'UserPool.Domain' \
    --output text 2>/dev/null || true)

  if [ -z "$COGNITO_DOMAIN" ] || [ "$COGNITO_DOMAIN" = "None" ]; then
    echo "  ⏭️  No Hosted UI domain attached to User Pool ${USER_POOL_ID}, skipping"
  else
    echo "  Deleting Hosted UI domain '${COGNITO_DOMAIN}'..."
    if aws cognito-idp delete-user-pool-domain \
      --domain "$COGNITO_DOMAIN" \
      --user-pool-id "$USER_POOL_ID" \
      --region "$REGION" 2>/dev/null; then
      echo "  ✅ Cognito domain deleted"
    else
      record_failure "Delete Cognito domain: ${COGNITO_DOMAIN}"
    fi
  fi
else
  echo "  ⏭️  No User Pool found, skipping domain deletion"
fi

echo ""

###############################################################################
# Step 5: Delete CloudWatch dashboard
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 5: Deleting CloudWatch dashboard..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

DASHBOARD_NAME="${COMPANY_NAME}-ai-gateway-${STAGE}"
if aws cloudwatch delete-dashboards --dashboard-names "$DASHBOARD_NAME" --region "$REGION" 2>/dev/null; then
  echo "  ✅ Dashboard '${DASHBOARD_NAME}' deleted"
else
  record_failure "Delete CloudWatch dashboard: ${DASHBOARD_NAME}"
fi

echo ""

###############################################################################
# Step 5b: Delete Bedrock Knowledge Base
#
# Must run BEFORE the CloudFormation stack deletion (Step 6) because the KB
# needs OpenSearch Serverless (in the mcp-tools CF stack) to be alive to
# clean up indexed vectors. Deleting after the stack causes DELETE_UNSUCCESSFUL.
#
# The KB ID is read from the search_kb Lambda's KNOWLEDGE_BASE_ID env var —
# the authoritative reference for which KB belongs to this deployment.
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 5a: Deleting Bedrock Knowledge Base..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

SEARCH_KB_LAMBDA="${CUSTOM_LAMBDAS_STACK}-search-kb"
KB_ID=$(aws lambda get-function-configuration \
    --function-name "$SEARCH_KB_LAMBDA" \
    --region "$REGION" \
    --query 'Environment.Variables.KNOWLEDGE_BASE_ID' \
    --output text 2>/dev/null || echo "")

if [ -z "$KB_ID" ] || [ "$KB_ID" = "None" ] || [ "$KB_ID" = "PENDING_PHASE2" ]; then
  echo "  ⏭️  No Knowledge Base ID found on Lambda '${SEARCH_KB_LAMBDA}' — skipping"
else
  echo "  Found KB: ${KB_ID} (from ${SEARCH_KB_LAMBDA} KNOWLEDGE_BASE_ID)"

  # Delete data sources first (OpenSearch is still alive here, so default
  # DELETE policy works — vectors are cleaned up cleanly)
  DS_IDS=$(aws bedrock-agent list-data-sources \
      --knowledge-base-id "$KB_ID" --region "$REGION" \
      --query "dataSourceSummaries[].dataSourceId" --output text 2>/dev/null || echo "")

  for ds_id in $DS_IDS; do
    [ -z "$ds_id" ] && continue
    if aws bedrock-agent delete-data-source \
        --knowledge-base-id "$KB_ID" --data-source-id "$ds_id" \
        --region "$REGION" >/dev/null 2>&1; then
      echo "  ✅ Data source '$ds_id' deleted"
    else
      record_failure "Delete KB data source: $ds_id"
    fi
  done

  # Delete the KB itself
  if aws bedrock-agent delete-knowledge-base \
      --knowledge-base-id "$KB_ID" \
      --region "$REGION" >/dev/null 2>&1; then
    echo "  ✅ Knowledge Base '${KB_ID}' deleted"
  else
    record_failure "Delete Knowledge Base: ${KB_ID}"
  fi
fi

echo ""

###############################################################################
# Step 5c: Delete inference profiles and BU routing table
#
# Application Inference Profiles and the routing table are created by
# scripts/create-aips.sh and scripts/create-team-config-table.sh rather than by
# CloudFormation, so stack deletion in Step 6 does not remove them. Without this
# step a teardown silently orphans one profile per (business unit, model) pair
# plus the DynamoDB table.
#
# Profile names come from config/bu-models.json, which is the source of truth for
# the matrix. .aip-map.json is also consulted when present so profiles are still
# cleaned up if the matrix has been edited since they were created.
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 5b: Deleting inference profiles and BU routing table..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

MATRIX_FILE="$PROJECT_ROOT/config/bu-models.json"
AIP_MAP_FILE="$PROJECT_ROOT/.aip-map.json"
TEAM_CONFIG_TABLE="ai-gateway-team-config"

PROFILE_NAMES=""
if [ -f "$MATRIX_FILE" ] && command -v jq >/dev/null 2>&1; then
  PROFILE_NAMES="$(jq -r '.businessUnits[].models[].profileName' "$MATRIX_FILE" 2>/dev/null || echo "")"
fi
if [ -f "$AIP_MAP_FILE" ] && command -v jq >/dev/null 2>&1; then
  PROFILE_NAMES="${PROFILE_NAMES}
$(jq -r '.[].profileName' "$AIP_MAP_FILE" 2>/dev/null || echo "")"
fi
PROFILE_NAMES="$(echo "$PROFILE_NAMES" | sed '/^$/d' | sort -u)"

if [ -z "$PROFILE_NAMES" ]; then
  echo "  ⏭️  No profile names resolved (no config/bu-models.json or jq) — skipping profiles"
else
  # --type-equals APPLICATION is required: list-inference-profiles returns only
  # SYSTEM_DEFINED profiles by default, so without it nothing is ever matched.
  #
  # A failure here is recorded rather than swallowed. Treating an API error as "no
  # profiles exist" makes every deletion report "not found, skipping", so the teardown
  # looks clean while leaving every profile in place — and the operator has no reason to
  # go back and check.
  if ! EXISTING_PROFILES="$(aws bedrock list-inference-profiles \
    --region "$REGION" \
    --type-equals APPLICATION \
    --max-results 1000 \
    --query "inferenceProfileSummaries[].[inferenceProfileName,inferenceProfileArn]" \
    --output text 2>&1)"; then
    record_failure "List inference profiles (none were deleted): ${EXISTING_PROFILES}"
    EXISTING_PROFILES=""
    PROFILE_NAMES=""
  fi

  while IFS= read -r pname; do
    [ -z "$pname" ] && continue
    # A name can match more than one profile if duplicates were ever created.
    MATCHES="$(echo "$EXISTING_PROFILES" | awk -v n="$pname" '$1 == n {print $2}')"
    if [ -z "$MATCHES" ]; then
      echo "  ⏭️  ${pname}: not found, skipping"
      continue
    fi
    while IFS= read -r arn; do
      [ -z "$arn" ] && continue
      if aws bedrock delete-inference-profile \
          --region "$REGION" \
          --inference-profile-identifier "$arn" >/dev/null 2>&1; then
        echo "  ✅ ${pname}: deleted ${arn##*/}"
      else
        record_failure "Delete inference profile: ${pname} (${arn})"
      fi
    done <<< "$MATCHES"
  done <<< "$PROFILE_NAMES"
fi

if aws dynamodb describe-table --table-name "$TEAM_CONFIG_TABLE" --region "$REGION" >/dev/null 2>&1; then
  if aws dynamodb delete-table --table-name "$TEAM_CONFIG_TABLE" --region "$REGION" >/dev/null 2>&1; then
    echo "  ✅ DynamoDB table '${TEAM_CONFIG_TABLE}' deletion started"
  else
    record_failure "Delete DynamoDB table: ${TEAM_CONFIG_TABLE}"
  fi
else
  echo "  ⏭️  DynamoDB table '${TEAM_CONFIG_TABLE}': does not exist, skipping"
fi

# Derived state: regenerated by scripts/create-aips.sh on the next deploy.
if [ -f "$AIP_MAP_FILE" ]; then
  rm -f "$AIP_MAP_FILE"
  echo "  ✅ Removed .aip-map.json"
fi

echo ""

###############################################################################
# Step 5c: Disable Bedrock invocation logging and delete log group
#
# scripts/enable-logging.py calls bedrock:PutModelInvocationLoggingConfiguration.
# Without this step the logging config survives teardown pointing at a deleted
# log group, and the log group itself incurs a small ongoing storage charge.
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 5c: Disabling Bedrock invocation logging and removing log group..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

BEDROCK_LOG_GROUP="/aws/bedrock/${COMPANY_NAME}-${STAGE}-invocations"

# Disable the logging config first (clear it to an empty config).
# Note: the Bedrock API requires at least one delivery destination, so a full
# disable is not possible via API. We delete the log group (below) and accept
# that the config will remain pointing at a non-existent group — it becomes a
# no-op and causes no errors. The IAM role is removed in Step 5d.
if aws bedrock get-model-invocation-logging-configuration \
    --region "$REGION" \
    --query 'loggingConfig.cloudWatchConfig.logGroupName' \
    --output text 2>/dev/null | grep -q .; then
  echo "  ℹ️  Bedrock logging config exists — will be a no-op after log group deletion (API does not support full disable)"
else
  echo "  ⏭️  Bedrock logging config not set, skipping"
fi

# Delete the log group.
if aws logs describe-log-groups \
    --log-group-name-prefix "$BEDROCK_LOG_GROUP" \
    --region "$REGION" \
    --query "logGroups[?logGroupName=='${BEDROCK_LOG_GROUP}'].logGroupName" \
    --output text 2>/dev/null | grep -q .; then
  if aws logs delete-log-group \
      --log-group-name "$BEDROCK_LOG_GROUP" \
      --region "$REGION" 2>/dev/null; then
    echo "  ✅ Log group '${BEDROCK_LOG_GROUP}' deleted"
  else
    record_failure "Delete CloudWatch log group: ${BEDROCK_LOG_GROUP}"
  fi
else
  echo "  ⏭️  Log group '${BEDROCK_LOG_GROUP}' not found, skipping"
fi

echo ""

###############################################################################
# Step 5d: Delete Bedrock invocation logging IAM role
#
# The bedrock logging IAM role is created by scripts/enable-logging.py
# via boto3, not by any CloudFormation stack, so it is not removed by stack
# deletion in Step 6.
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 5d: Deleting Bedrock invocation logging IAM role..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

BEDROCK_LOGGING_ROLE="${COMPANY_NAME}-${STAGE}-bedrock-logging-role"

if aws iam get-role --role-name "$BEDROCK_LOGGING_ROLE" >/dev/null 2>&1; then
  # Delete inline policies before deleting the role.
  for P in $(aws iam list-role-policies --role-name "$BEDROCK_LOGGING_ROLE" \
      --query 'PolicyNames' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "$BEDROCK_LOGGING_ROLE" \
        --policy-name "$P" 2>/dev/null || true
  done
  if aws iam delete-role --role-name "$BEDROCK_LOGGING_ROLE" 2>/dev/null; then
    echo "  ✅ IAM role '${BEDROCK_LOGGING_ROLE}' deleted"
  else
    record_failure "Delete IAM role: ${BEDROCK_LOGGING_ROLE}"
  fi
else
  echo "  ⏭️  IAM role '${BEDROCK_LOGGING_ROLE}' not found, skipping"
fi

echo ""

###############################################################################
# Step 5f: Delete AWS Budget and SNS alert topic
#
# scripts/create-budget-alert.py creates a named budget and an SNS topic.
# Neither is managed by CloudFormation, so they outlive stack deletion.
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 5f: Deleting AWS Budget and SNS alert topic..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

BUDGET_NAME="${COMPANY_NAME}-ai-gateway-${STAGE}"
SNS_TOPIC_NAME="${COMPANY_NAME}-${STAGE}-budget-alert"

# Budgets API requires the account ID.
if [ -z "${ACCOUNT_ID:-}" ]; then
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
fi

if [ -n "$ACCOUNT_ID" ]; then
  if aws budgets describe-budget \
      --account-id "$ACCOUNT_ID" \
      --budget-name "$BUDGET_NAME" \
      --region "us-east-1" >/dev/null 2>&1; then
    if aws budgets delete-budget \
        --account-id "$ACCOUNT_ID" \
        --budget-name "$BUDGET_NAME" \
        --region "us-east-1" 2>/dev/null; then
      echo "  ✅ Budget '${BUDGET_NAME}' deleted"
    else
      record_failure "Delete AWS Budget: ${BUDGET_NAME}"
    fi
  else
    echo "  ⏭️  Budget '${BUDGET_NAME}' not found, skipping"
  fi
else
  record_failure "Could not resolve account ID — skipping budget deletion"
fi

# SNS topic ARN is account+region scoped.
SNS_TOPIC_ARN="arn:aws:sns:${REGION}:${ACCOUNT_ID}:${SNS_TOPIC_NAME}"
if aws sns get-topic-attributes --topic-arn "$SNS_TOPIC_ARN" --region "$REGION" >/dev/null 2>&1; then
  if aws sns delete-topic --topic-arn "$SNS_TOPIC_ARN" --region "$REGION" 2>/dev/null; then
    echo "  ✅ SNS topic '${SNS_TOPIC_NAME}' deleted"
  else
    record_failure "Delete SNS topic: ${SNS_TOPIC_NAME}"
  fi
else
  echo "  ⏭️  SNS topic '${SNS_TOPIC_NAME}' not found, skipping"
fi

echo ""

###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 6: Deleting CloudFormation stacks..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

delete_stack() {
  local stack_name="$1"

  if ! aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" >/dev/null 2>&1; then
    echo "  ⏭️  ${stack_name}: does not exist, skipping"
    return
  fi

  echo "  🗑️  Deleting ${stack_name}..."
  aws cloudformation delete-stack --stack-name "$stack_name" --region "$REGION"
  echo "  ⏳ Waiting for ${stack_name} deletion..."

  if aws cloudformation wait stack-delete-complete --stack-name "$stack_name" --region "$REGION" 2>/dev/null; then
    echo "  ✅ ${stack_name} deleted"
  else
    record_failure "Delete CloudFormation stack: ${stack_name}"
  fi
}

# Delete in reverse dependency order
delete_stack "$FRONTEND_STACK"
delete_stack "$CUSTOM_LAMBDAS_STACK"
delete_stack "$GATEWAY_STACK"

echo ""

###############################################################################
# Step 7: Remove vendor/ directory contents (if present from older deploys)
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 7: Removing vendor/ directory contents..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

VENDOR_DIR="${PROJECT_ROOT}/vendor"

if [ -d "$VENDOR_DIR" ]; then
  rm -rf "${VENDOR_DIR:?}/"*
  echo "  ✅ vendor/ directory emptied"
else
  echo "  ⏭️  vendor/ directory not found, skipping"
fi

echo ""

###############################################################################
# Summary
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Cleanup Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ ${#FAILURES[@]} -eq 0 ]; then
  echo ""
  echo "  ✅ All POC resources successfully deleted!"
  echo ""
else
  echo ""
  echo "  ⚠️  Cleanup completed with ${#FAILURES[@]} failure(s):"
  echo ""
  for failure in "${FAILURES[@]}"; do
    echo "    ❌ ${failure}"
  done
  echo ""
  echo "  Please review and manually clean up the above resources."
  echo ""
  exit 1
fi
