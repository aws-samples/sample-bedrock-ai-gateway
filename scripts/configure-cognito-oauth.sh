#!/bin/bash
set -e

# Configure Cognito Hosted UI and OAuth2 settings
# Usage: ./scripts/configure-cognito-oauth.sh --user-pool-id <id> --app-client-id <id> --cloudfront-domain <url> [--region <region>]

USER_POOL_ID=""
APP_CLIENT_ID=""
CLOUDFRONT_DOMAIN=""
REGION="us-east-1"
DOMAIN_PREFIX="ai-gateway-poc"

while [[ $# -gt 0 ]]; do
  case $1 in
    --user-pool-id)    USER_POOL_ID="$2";    shift 2 ;;
    --app-client-id)   APP_CLIENT_ID="$2";   shift 2 ;;
    --cloudfront-domain) CLOUDFRONT_DOMAIN="$2"; shift 2 ;;
    --region)          REGION="$2";          shift 2 ;;
    --domain-prefix)   DOMAIN_PREFIX="$2";   shift 2 ;;
    # Legacy positional support
    *) 
      if [ -z "$USER_POOL_ID" ]; then USER_POOL_ID="$1"
      elif [ -z "$APP_CLIENT_ID" ]; then APP_CLIENT_ID="$1"
      elif [ -z "$CLOUDFRONT_DOMAIN" ]; then CLOUDFRONT_DOMAIN="$1"
      elif [ "$REGION" = "us-east-1" ]; then REGION="$1"
      fi
      shift ;;
  esac
done

if [ -z "$USER_POOL_ID" ] || [ -z "$APP_CLIENT_ID" ] || [ -z "$CLOUDFRONT_DOMAIN" ]; then
  echo "Usage: $0 --user-pool-id <id> --app-client-id <id> --cloudfront-domain <url> [--region <region>]"
  exit 1
fi

echo "🔐 Configuring Cognito OAuth2 settings..."
echo "   User Pool ID: ${USER_POOL_ID}"
echo "   App Client ID: ${APP_CLIENT_ID}"
echo "   CloudFront Domain: ${CLOUDFRONT_DOMAIN}"
echo "   Region: ${REGION}"
echo ""

# Step 1: Create Cognito Hosted UI domain (ignore error if already exists)
echo "📌 Creating Cognito Hosted UI domain: ${DOMAIN_PREFIX}..."
if aws cognito-idp create-user-pool-domain \
    --user-pool-id "${USER_POOL_ID}" \
    --domain "${DOMAIN_PREFIX}" \
    --region "${REGION}" 2>/dev/null; then
    echo "   ✅ Domain created: ${DOMAIN_PREFIX}"
else
    echo "   ⚠️  Domain already exists or could not be created (continuing...)"
fi

# Step 2: Update App Client with OAuth2 settings
echo "📌 Updating App Client OAuth2 settings..."
aws cognito-idp update-user-pool-client \
    --user-pool-id "${USER_POOL_ID}" \
    --client-id "${APP_CLIENT_ID}" \
    --allowed-o-auth-flows "code" \
    --allowed-o-auth-scopes "openid" "profile" "email" \
    --callback-urls "https://${CLOUDFRONT_DOMAIN}/callback" \
    --logout-urls "https://${CLOUDFRONT_DOMAIN}" \
    --supported-identity-providers "COGNITO" \
    --allowed-o-auth-flows-user-pool-client \
    --region "${REGION}" > /dev/null

echo "   ✅ App Client OAuth2 settings updated"
echo ""

# Print Cognito Hosted UI URL
COGNITO_LOGIN_URL="https://${DOMAIN_PREFIX}.auth.${REGION}.amazoncognito.com/login?client_id=${APP_CLIENT_ID}&response_type=code&scope=openid+profile+email&redirect_uri=https://${CLOUDFRONT_DOMAIN}/callback"

echo "✅ Cognito OAuth2 configuration complete!"
echo ""
echo "   Cognito Hosted UI Login URL:"
echo "   ${COGNITO_LOGIN_URL}"
echo ""
