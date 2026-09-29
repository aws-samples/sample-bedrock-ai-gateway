#!/bin/bash

# AI Gateway POC — Phase 2 Deployment
# Creates the Bedrock Knowledge Base after the OpenSearch collection from Phase 1 is ACTIVE.
#
# Usage: ./deploy-phase2.sh --region <aws-region> [--stage poc]

set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   AI Gateway POC — Phase 2 Deployment                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "⚠️  PHASE 2 DEPLOYMENT"
echo "This script creates the Bedrock Knowledge Base after the OpenSearch"
echo "collection from Phase 1 has become ACTIVE (takes 10-15 minutes)."
echo ""
echo "If you just ran deploy.sh, wait 10-15 minutes before running this script."
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
      echo "Usage: ./deploy-phase2.sh --region <aws-region> [--stage poc] [--company-name anycompany] [--profile <aws-profile>]"
      exit 1
      ;;
  esac
done

if [ -z "$REGION" ]; then
  echo "❌ ERROR: --region is required"
  echo "Usage: ./deploy-phase2.sh --region <aws-region> [--stage poc] [--company-name anycompany] [--profile <aws-profile>]"
  exit 1
fi

export AWS_REGION="$REGION"
export AWS_DEFAULT_REGION="$REGION"
[ -n "$PROFILE" ] && export AWS_PROFILE="$PROFILE"

CUSTOM_LAMBDAS_STACK="${COMPANY_NAME}-mcp-tools-${STAGE}"
KB_NAME="${COMPANY_NAME}-kb-${STAGE}"
DS_NAME="${COMPANY_NAME}-kb-docs"
COLLECTION_NAME="${COMPANY_NAME}-kb-${STAGE}"
INDEX_NAME="bedrock-knowledge-base-default-index"
KB_DOCS_DIR="custom-lambdas/kb-docs"

echo "Configuration:"
echo "  Region:  $REGION"
echo "  Stage:   $STAGE"
echo "  Stack:   $CUSTOM_LAMBDAS_STACK"
echo ""
echo "  aws opensearchserverless batch-get-collection --names $COLLECTION_NAME --region $REGION --query 'collectionDetails[0].status'"
echo ""

###############################################################################
# Python virtual environment setup (idempotent — mirrors deploy.sh)
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Setting up Python virtual environment..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if ! command -v python3 &>/dev/null; then
  echo "❌ python3 is required but not found. Install it and re-run."
  exit 1
fi

# Resolve project root (this script lives at the project root, same as deploy.sh)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -d "${SCRIPT_DIR}/.venv" ]; then
  echo "  📦 Creating .venv..."
  python3 -m venv "${SCRIPT_DIR}/.venv"
fi

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/.venv/bin/activate"

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
# Prerequisites check
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Checking prerequisites..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if ! command -v aws &>/dev/null; then
  echo "❌ AWS CLI is required but not found"
  exit 1
fi

echo "  ✅ All prerequisites satisfied"
echo ""

###############################################################################
# Step 0: Read stack outputs
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 0: Reading stack outputs from ${CUSTOM_LAMBDAS_STACK}..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if ! aws cloudformation describe-stacks --stack-name "$CUSTOM_LAMBDAS_STACK" --region "$REGION" >/dev/null 2>&1; then
  echo "❌ Stack ${CUSTOM_LAMBDAS_STACK} not found. Run deploy.sh (Phase 1) first."
  exit 1
fi

COLLECTION_ARN=$(aws cloudformation describe-stacks --stack-name "$CUSTOM_LAMBDAS_STACK" \
  --query 'Stacks[0].Outputs[?OutputKey==`OpenSearchCollectionArn`].OutputValue' \
  --output text --region "$REGION")

COLLECTION_ENDPOINT=$(aws cloudformation describe-stacks --stack-name "$CUSTOM_LAMBDAS_STACK" \
  --query 'Stacks[0].Outputs[?OutputKey==`OpenSearchCollectionEndpoint`].OutputValue' \
  --output text --region "$REGION")

KB_ROLE_ARN=$(aws cloudformation describe-stacks --stack-name "$CUSTOM_LAMBDAS_STACK" \
  --query 'Stacks[0].Outputs[?OutputKey==`KBRoleArn`].OutputValue' \
  --output text --region "$REGION")

KB_S3_BUCKET=$(aws cloudformation describe-stacks --stack-name "$CUSTOM_LAMBDAS_STACK" \
  --query 'Stacks[0].Outputs[?OutputKey==`KBSourceBucketName`].OutputValue' \
  --output text --region "$REGION")

SEARCH_KB_LAMBDA=$(aws cloudformation describe-stacks --stack-name "$CUSTOM_LAMBDAS_STACK" \
  --query 'Stacks[0].Outputs[?OutputKey==`SearchKBLambdaArn`].OutputValue' \
  --output text --region "$REGION")

# Validate we got all required outputs
MISSING=""
[ -z "$COLLECTION_ARN" ]      && MISSING="$MISSING OpenSearchCollectionArn"
[ -z "$COLLECTION_ENDPOINT" ] && MISSING="$MISSING OpenSearchCollectionEndpoint"
[ -z "$KB_ROLE_ARN" ]         && MISSING="$MISSING KBRoleArn"
[ -z "$KB_S3_BUCKET" ]        && MISSING="$MISSING KBSourceBucketName"
[ -z "$SEARCH_KB_LAMBDA" ]    && MISSING="$MISSING SearchKBLambdaArn"

if [ -n "$MISSING" ]; then
  echo "❌ Missing stack outputs:${MISSING}"
  echo "   Ensure custom-lambdas/template.yaml exports these output keys."
  exit 1
fi

echo "  ✅ Stack outputs retrieved"
echo "     Collection ARN:      ${COLLECTION_ARN}"
echo "     Collection Endpoint: ${COLLECTION_ENDPOINT}"
echo "     KB Role ARN:         ${KB_ROLE_ARN}"
echo "     S3 Bucket:           ${KB_S3_BUCKET}"
echo "     search_kb Lambda:    ${SEARCH_KB_LAMBDA}"
echo ""

###############################################################################
# Step 1: Check OpenSearch collection status
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 1: Checking OpenSearch collection status..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

COLLECTION_STATUS=$(aws opensearchserverless batch-get-collection \
  --names "$COLLECTION_NAME" \
  --region "$REGION" \
  --query 'collectionDetails[0].status' \
  --output text 2>/dev/null || echo "NOT_FOUND")

echo "  Collection '${COLLECTION_NAME}' status: ${COLLECTION_STATUS}"

if [ "$COLLECTION_STATUS" != "ACTIVE" ]; then
  echo ""
  echo "❌ OpenSearch collection is not yet ACTIVE (current status: ${COLLECTION_STATUS})"
  echo ""
  echo "   Wait 10-15 minutes and check again:"
  echo "   aws opensearchserverless batch-get-collection --names ${COLLECTION_NAME} --region ${REGION} --query 'collectionDetails[0].status'"
  echo ""
  echo "   Then re-run this script once the status is ACTIVE."
  exit 1
fi

echo "  ✅ Collection is ACTIVE — proceeding"
echo ""

###############################################################################
# Step 2: Check if KB already exists (idempotency)
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 2: Checking if Knowledge Base already exists..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

EXISTING_KB_ID=$(aws bedrock-agent list-knowledge-bases \
  --region "$REGION" \
  --query "knowledgeBaseSummaries[?name=='${KB_NAME}'].knowledgeBaseId" \
  --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_KB_ID" ] && [ "$EXISTING_KB_ID" != "None" ]; then
  echo "  ⏭️  Knowledge Base '${KB_NAME}' already exists (ID: ${EXISTING_KB_ID})"
  echo "     Skipping KB creation — will update Lambda env var at the end."
  KB_ID="$EXISTING_KB_ID"
  SKIP_KB_CREATION=true
else
  echo "  ℹ️  No existing KB found — will create new one"
  SKIP_KB_CREATION=false
fi
echo ""

###############################################################################
# Step 3: Create OpenSearch vector index
###############################################################################
if [ "$SKIP_KB_CREATION" = false ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Step 3: Creating OpenSearch vector index..."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Strip trailing slash from endpoint
  ENDPOINT="${COLLECTION_ENDPOINT%/}"

  python3 - <<PYEOF
import sys
import boto3
from opensearchpy import OpenSearch, RequestsHttpConnection
from requests_aws4auth import AWS4Auth

region = "${REGION}"
endpoint = "${ENDPOINT}"
index_name = "${INDEX_NAME}"

# Build AWS4Auth from current session credentials
session = boto3.Session()
credentials = session.get_credentials().get_frozen_credentials()
awsauth = AWS4Auth(
    credentials.access_key,
    credentials.secret_key,
    region,
    "aoss",
    session_token=credentials.token
)

host = endpoint.replace("https://", "").replace("http://", "")
client = OpenSearch(
    hosts=[{"host": host, "port": 443}],
    http_auth=awsauth,
    use_ssl=True,
    verify_certs=True,
    connection_class=RequestsHttpConnection,
    timeout=30
)

# Check if index already exists
if client.indices.exists(index=index_name):
    print(f"  ⏭️  Index '{index_name}' already exists — skipping creation")
    sys.exit(0)

index_body = {
    "settings": {
        "index.knn": True
    },
    "mappings": {
        "properties": {
            "bedrock-knowledge-base-default-vector": {
                "type": "knn_vector",
                "dimension": 1536,
                "method": {
                    "name": "hnsw",
                    "space_type": "l2",
                    "engine": "faiss",
                    "parameters": {
                        "ef_construction": 512,
                        "m": 16
                    }
                }
            },
            "AMAZON_BEDROCK_TEXT_CHUNK": {
                "type": "text"
            },
            "AMAZON_BEDROCK_METADATA": {
                "type": "text",
                "index": False
            }
        }
    }
}

response = client.indices.create(index=index_name, body=index_body)
print(f"  ✅ Index '{index_name}' created: {response}")
PYEOF

  echo "  ✅ OpenSearch vector index ready"
  echo ""
fi

###############################################################################
# Step 4: Create Bedrock Knowledge Base
###############################################################################
if [ "$SKIP_KB_CREATION" = false ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Step 4: Creating Bedrock Knowledge Base..."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  KB_RESPONSE=$(aws bedrock-agent create-knowledge-base \
    --name "$KB_NAME" \
    --description "${COMPANY_NAME} AI Gateway POC Knowledge Base" \
    --role-arn "$KB_ROLE_ARN" \
    --knowledge-base-configuration '{
      "type": "VECTOR",
      "vectorKnowledgeBaseConfiguration": {
        "embeddingModelArn": "arn:aws:bedrock:'"$REGION"'::foundation-model/amazon.titan-embed-text-v1"
      }
    }' \
    --storage-configuration '{
      "type": "OPENSEARCH_SERVERLESS",
      "opensearchServerlessConfiguration": {
        "collectionArn": "'"$COLLECTION_ARN"'",
        "vectorIndexName": "'"$INDEX_NAME"'",
        "fieldMapping": {
          "vectorField": "bedrock-knowledge-base-default-vector",
          "textField": "AMAZON_BEDROCK_TEXT_CHUNK",
          "metadataField": "AMAZON_BEDROCK_METADATA"
        }
      }
    }' \
    --region "$REGION" \
    --output json)

  KB_ID=$(echo "$KB_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['knowledgeBase']['knowledgeBaseId'])")

  echo "  ✅ Knowledge Base created"
  echo "     KB ID: ${KB_ID}"
  echo ""

  # Wait for KB to become ACTIVE
  echo "  ⏳ Waiting for Knowledge Base to become ACTIVE..."
  for i in $(seq 1 30); do
    KB_STATUS=$(aws bedrock-agent get-knowledge-base \
      --knowledge-base-id "$KB_ID" \
      --region "$REGION" \
      --query 'knowledgeBase.status' \
      --output text 2>/dev/null || echo "CREATING")
    if [ "$KB_STATUS" = "ACTIVE" ]; then
      echo "  ✅ Knowledge Base is ACTIVE"
      break
    fi
    echo "     Status: ${KB_STATUS} — waiting 10s... (attempt ${i}/30)"
    sleep 10
  done

  if [ "$KB_STATUS" != "ACTIVE" ]; then
    echo "❌ Knowledge Base did not become ACTIVE within 5 minutes. Check AWS Console."
    exit 1
  fi
  echo ""
fi

###############################################################################
# Step 5: Create data source
###############################################################################
if [ "$SKIP_KB_CREATION" = false ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Step 5: Creating KB data source..."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  DS_RESPONSE=$(aws bedrock-agent create-data-source \
    --knowledge-base-id "$KB_ID" \
    --name "$DS_NAME" \
    --description "AI Gateway KB documents from S3" \
    --data-source-configuration '{
      "type": "S3",
      "s3Configuration": {
        "bucketArn": "arn:aws:s3:::'"$KB_S3_BUCKET"'"
      }
    }' \
    --region "$REGION" \
    --output json)

  DS_ID=$(echo "$DS_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['dataSource']['dataSourceId'])")

  echo "  ✅ Data source created"
  echo "     Data Source ID: ${DS_ID}"
  echo ""
else
  # KB exists — look up the existing data source ID
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Step 5: Looking up existing data source..."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  DS_ID=$(aws bedrock-agent list-data-sources \
    --knowledge-base-id "$KB_ID" \
    --region "$REGION" \
    --query 'dataSourceSummaries[0].dataSourceId' \
    --output text 2>/dev/null || echo "")

  if [ -z "$DS_ID" ] || [ "$DS_ID" = "None" ]; then
    echo "❌ No data source found for KB ${KB_ID}. Cannot trigger ingestion."
    exit 1
  fi

  echo "  ✅ Found existing data source: ${DS_ID}"
  echo ""
fi

###############################################################################
# Step 6: Upload KB documents to S3
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 6: Uploading KB documents to S3..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ ! -d "$KB_DOCS_DIR" ]; then
  echo "⚠️  KB docs directory '${KB_DOCS_DIR}' not found — skipping upload"
else
  DOC_COUNT=$(find "$KB_DOCS_DIR" -type f | wc -l | tr -d ' ')
  echo "  📄 Found ${DOC_COUNT} document(s) in ${KB_DOCS_DIR}"

  aws s3 sync "$KB_DOCS_DIR/" "s3://${KB_S3_BUCKET}/" \
    --region "$REGION" \
    --delete

  echo "  ✅ Documents uploaded to s3://${KB_S3_BUCKET}/"
fi
echo ""

###############################################################################
# Step 7: Start ingestion job
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 7: Starting ingestion job..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

INGESTION_RESPONSE=$(aws bedrock-agent start-ingestion-job \
  --knowledge-base-id "$KB_ID" \
  --data-source-id "$DS_ID" \
  --region "$REGION" \
  --output json)

INGESTION_JOB_ID=$(echo "$INGESTION_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['ingestionJob']['ingestionJobId'])")

echo "  ✅ Ingestion job started: ${INGESTION_JOB_ID}"
echo "  ⏳ Waiting for ingestion to complete (polling every 10s)..."
echo ""

###############################################################################
# Step 8: Wait for ingestion to complete
###############################################################################
INGESTION_STATUS="STARTING"
ATTEMPT=0
MAX_ATTEMPTS=60  # 10 minutes max

while [ "$INGESTION_STATUS" != "COMPLETE" ] && [ "$INGESTION_STATUS" != "FAILED" ]; do
  ATTEMPT=$((ATTEMPT + 1))
  if [ "$ATTEMPT" -gt "$MAX_ATTEMPTS" ]; then
    echo "❌ Ingestion job timed out after 10 minutes. Check AWS Console."
    exit 1
  fi

  sleep 10

  INGESTION_DETAILS=$(aws bedrock-agent get-ingestion-job \
    --knowledge-base-id "$KB_ID" \
    --data-source-id "$DS_ID" \
    --ingestion-job-id "$INGESTION_JOB_ID" \
    --region "$REGION" \
    --output json 2>/dev/null)

  INGESTION_STATUS=$(echo "$INGESTION_DETAILS" | python3 -c "import sys,json; print(json.load(sys.stdin)['ingestionJob']['status'])" 2>/dev/null || echo "UNKNOWN")
  DOCS_INDEXED=$(echo "$INGESTION_DETAILS" | python3 -c "import sys,json; d=json.load(sys.stdin)['ingestionJob'].get('statistics',{}); print(d.get('numberOfNewDocumentsIndexed',0) + d.get('numberOfModifiedDocumentsIndexed',0))" 2>/dev/null || echo "?")
  DOCS_FAILED=$(echo "$INGESTION_DETAILS" | python3 -c "import sys,json; d=json.load(sys.stdin)['ingestionJob'].get('statistics',{}); print(d.get('numberOfDocumentsFailed',0))" 2>/dev/null || echo "?")

  echo "  Status: ${INGESTION_STATUS} | Indexed: ${DOCS_INDEXED} | Failed: ${DOCS_FAILED} (attempt ${ATTEMPT}/${MAX_ATTEMPTS})"
done

if [ "$INGESTION_STATUS" = "FAILED" ]; then
  echo ""
  echo "❌ Ingestion job FAILED. Check the AWS Console for details:"
  echo "   https://console.aws.amazon.com/bedrock/home?region=${REGION}#/knowledge-bases/${KB_ID}"
  exit 1
fi

echo ""
echo "  ✅ Ingestion complete — ${DOCS_INDEXED} document(s) indexed, ${DOCS_FAILED} failed"
echo ""

###############################################################################
# Step 9: Update search_kb Lambda env var
###############################################################################
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 9: Updating search_kb Lambda environment variable..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Get current env vars to preserve any existing ones
CURRENT_ENV=$(aws lambda get-function-configuration \
  --function-name "$SEARCH_KB_LAMBDA" \
  --region "$REGION" \
  --query 'Environment.Variables' \
  --output json 2>/dev/null || echo "{}")

# Merge KNOWLEDGE_BASE_ID into existing env vars using Python.
# Emit the full {"Variables": {...}} structure so it can be passed as JSON
# to --environment (the shorthand Variables={k=v} form cannot handle JSON).
MERGED_ENV=$(echo "$CURRENT_ENV" | python3 -c "
import sys, json
env = json.load(sys.stdin) or {}
env['KNOWLEDGE_BASE_ID'] = '${KB_ID}'
print(json.dumps({'Variables': env}))
")

aws lambda update-function-configuration \
  --function-name "$SEARCH_KB_LAMBDA" \
  --environment "$MERGED_ENV" \
  --region "$REGION" \
  --output text >/dev/null

echo "  ✅ Lambda '${SEARCH_KB_LAMBDA}' updated with KNOWLEDGE_BASE_ID=${KB_ID}"
echo ""

###############################################################################
# Success summary
###############################################################################
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                                                            ║"
echo "║   ✅ Phase 2 Deployment Complete!                          ║"
echo "║                                                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "   Knowledge Base ID:  ${KB_ID}"
echo "   Data Source ID:     ${DS_ID}"
echo "   Ingestion Job ID:   ${INGESTION_JOB_ID}"
echo "   Documents indexed:  ${DOCS_INDEXED}"
echo "   Lambda updated:     ${SEARCH_KB_LAMBDA}"
echo ""
echo "   The search_kb Lambda is now connected to the Knowledge Base."
echo "   You can test it by asking a question in the Client UI that"
echo "   requires knowledge base lookup."
echo ""
echo "   KB Console:"
echo "   https://console.aws.amazon.com/bedrock/home?region=${REGION}#/knowledge-bases/${KB_ID}"
echo ""

# Patch .env.md with Phase 2 values if it exists
if [ -f "${ROOT_DIR}/.env.md" ]; then
  # Replace placeholder lines with real values
  sed -i.bak \
    -e "s|Knowledge Base ID | (run deploy-phase2.sh)|Knowledge Base ID | ${KB_ID}|g" \
    -e "s|KB Data Source ID | (run deploy-phase2.sh)|KB Data Source ID | ${DS_ID}|g" \
    "${ROOT_DIR}/.env.md" 2>/dev/null || true
  rm -f "${ROOT_DIR}/.env.md.bak"
  # Append Phase 2 section if not already present
  if ! grep -q "KB_ID.*${KB_ID}" "${ROOT_DIR}/.env.md" 2>/dev/null; then
    cat >> "${ROOT_DIR}/.env.md" << P2EOF

## Phase 2 Resources (populated by deploy-phase2.sh)

| Resource | ID |
|----------|-----|
| Knowledge Base ID | ${KB_ID} |
| KB Data Source ID | ${DS_ID} |
| KB Ingestion Job ID | ${INGESTION_JOB_ID} |
| Documents Indexed | ${DOCS_INDEXED} |
P2EOF
  fi
  echo "  ✅ .env.md updated with Phase 2 resource IDs"
fi
