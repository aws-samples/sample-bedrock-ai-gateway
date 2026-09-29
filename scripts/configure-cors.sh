#!/bin/bash
set -e

# Configure CORS on API Gateway for the Client UI hosted on CloudFront
# Usage: ./scripts/configure-cors.sh <api-id> <stage-name> <cloudfront-domain>

API_ID="$1"
STAGE_NAME="$2"
CLOUDFRONT_DOMAIN="$3"

if [ -z "$API_ID" ] || [ -z "$STAGE_NAME" ] || [ -z "$CLOUDFRONT_DOMAIN" ]; then
  echo "❌ Usage: $0 <api-gateway-id> <stage-name> <cloudfront-domain>"
  echo "   Example: $0 abc123def4 poc d1234567890.cloudfront.net"
  exit 1
fi

ALLOWED_ORIGIN="https://${CLOUDFRONT_DOMAIN}"
ALLOWED_HEADERS="Content-Type,Authorization,X-Api-Key"
ALLOWED_METHODS="POST,OPTIONS"

echo "🔧 Configuring CORS on API Gateway ${API_ID} for origin: ${ALLOWED_ORIGIN}"

# --- Step 1: Get the root resource ID and proxy resource ---
echo "  → Finding API resources..."
RESOURCES=$(aws apigateway get-resources --rest-api-id "$API_ID" --query 'items' --output json)

# Find the proxy resource (/{proxy+}) or root resource
PROXY_RESOURCE_ID=$(echo "$RESOURCES" | python3 -c "
import json, sys
resources = json.load(sys.stdin)
for r in resources:
    if r.get('pathPart') == '{proxy+}':
        print(r['id'])
        sys.exit(0)
# Fallback: use root resource
for r in resources:
    if r.get('path') == '/':
        print(r['id'])
        sys.exit(0)
" 2>/dev/null || true)

if [ -z "$PROXY_RESOURCE_ID" ]; then
  echo "❌ Could not find proxy resource or root resource on API ${API_ID}"
  exit 1
fi

echo "  → Found resource ID: ${PROXY_RESOURCE_ID}"

# --- Step 2: Create OPTIONS method with Mock integration for preflight ---
echo "  → Creating OPTIONS method on proxy resource..."

# Delete existing OPTIONS method if present (ignore errors)
aws apigateway delete-method \
  --rest-api-id "$API_ID" \
  --resource-id "$PROXY_RESOURCE_ID" \
  --http-method OPTIONS 2>/dev/null || true

# Create OPTIONS method (no authorization)
aws apigateway put-method \
  --rest-api-id "$API_ID" \
  --resource-id "$PROXY_RESOURCE_ID" \
  --http-method OPTIONS \
  --authorization-type NONE \
  --no-api-key-required

# Create Mock integration for OPTIONS
aws apigateway put-integration \
  --rest-api-id "$API_ID" \
  --resource-id "$PROXY_RESOURCE_ID" \
  --http-method OPTIONS \
  --type MOCK \
  --request-templates '{"application/json": "{\"statusCode\": 200}"}'

# Create method response for OPTIONS (200)
aws apigateway put-method-response \
  --rest-api-id "$API_ID" \
  --resource-id "$PROXY_RESOURCE_ID" \
  --http-method OPTIONS \
  --status-code 200 \
  --response-parameters '{
    "method.response.header.Access-Control-Allow-Origin": false,
    "method.response.header.Access-Control-Allow-Headers": false,
    "method.response.header.Access-Control-Allow-Methods": false
  }' \
  --response-models '{"application/json": "Empty"}'

# Create integration response for OPTIONS with CORS headers
aws apigateway put-integration-response \
  --rest-api-id "$API_ID" \
  --resource-id "$PROXY_RESOURCE_ID" \
  --http-method OPTIONS \
  --status-code 200 \
  --response-parameters "{
    \"method.response.header.Access-Control-Allow-Origin\": \"'${ALLOWED_ORIGIN}'\",
    \"method.response.header.Access-Control-Allow-Headers\": \"'${ALLOWED_HEADERS}'\",
    \"method.response.header.Access-Control-Allow-Methods\": \"'${ALLOWED_METHODS}'\"
  }" \
  --response-templates '{"application/json": ""}'

echo "  ✅ OPTIONS preflight configured"

# --- Step 3: Configure DEFAULT_4XX Gateway Response with CORS headers ---
echo "  → Configuring DEFAULT_4XX Gateway Response..."
aws apigateway put-gateway-response \
  --rest-api-id "$API_ID" \
  --response-type DEFAULT_4XX \
  --response-parameters "{
    \"gatewayresponse.header.Access-Control-Allow-Origin\": \"'${ALLOWED_ORIGIN}'\",
    \"gatewayresponse.header.Access-Control-Allow-Headers\": \"'${ALLOWED_HEADERS}'\",
    \"gatewayresponse.header.Access-Control-Allow-Methods\": \"'${ALLOWED_METHODS}'\"
  }"

echo "  ✅ DEFAULT_4XX Gateway Response configured"

# --- Step 4: Configure DEFAULT_5XX Gateway Response with CORS headers ---
echo "  → Configuring DEFAULT_5XX Gateway Response..."
aws apigateway put-gateway-response \
  --rest-api-id "$API_ID" \
  --response-type DEFAULT_5XX \
  --response-parameters "{
    \"gatewayresponse.header.Access-Control-Allow-Origin\": \"'${ALLOWED_ORIGIN}'\",
    \"gatewayresponse.header.Access-Control-Allow-Headers\": \"'${ALLOWED_HEADERS}'\",
    \"gatewayresponse.header.Access-Control-Allow-Methods\": \"'${ALLOWED_METHODS}'\"
  }"

echo "  ✅ DEFAULT_5XX Gateway Response configured"

# --- Step 5: Redeploy the API stage ---
echo "  → Redeploying API to stage '${STAGE_NAME}'..."
aws apigateway create-deployment \
  --rest-api-id "$API_ID" \
  --stage-name "$STAGE_NAME" \
  --description "CORS configuration update"

echo "✅ CORS configuration complete for API ${API_ID} (stage: ${STAGE_NAME})"
echo "   Allowed Origin: ${ALLOWED_ORIGIN}"
echo "   Allowed Headers: ${ALLOWED_HEADERS}"
echo "   Allowed Methods: ${ALLOWED_METHODS}"
