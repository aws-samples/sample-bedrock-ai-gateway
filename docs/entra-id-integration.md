# Entra ID Integration Guide

This guide describes how to swap the POC's Cognito-only authentication for Azure Entra ID (formerly Azure AD) federation. The key insight: **no frontend code changes are needed**. Cognito Hosted UI handles the federation transparently.

## Overview

The POC uses Cognito Hosted UI with OAuth2/PKCE. Adding Entra ID as a federated identity provider means:

1. Users see an "Entra ID" button on the Cognito Hosted UI login page
2. Clicking it redirects to Microsoft's login page
3. After authentication, Microsoft redirects back to Cognito
4. Cognito issues its own tokens (with mapped claims) back to the Client UI
5. The Client UI continues using Cognito tokens — no code changes

```
User → Client UI → Cognito Hosted UI → "Sign in with Entra ID" button
     → Microsoft login page → authenticate
     → Redirect back to Cognito → Cognito issues tokens
     → Redirect to Client UI /callback → normal PKCE token exchange
```

## Prerequisites

- Azure Entra ID tenant with admin access
- Cognito User Pool already deployed (from the POC)
- The CloudFront domain URL (callback URL)

## Step 1: Register an Application in Azure Entra ID

1. Go to **Azure Portal → Microsoft Entra ID → App registrations → New registration**
2. Configure:
   - **Name**: `AI Gateway POC`
   - **Supported account types**: Single tenant (or multi-tenant if needed)
   - **Redirect URI**: `https://<cognito-domain>.auth.<region>.amazoncognito.com/oauth2/idpresponse`
3. After creation, note:
   - **Application (client) ID** — this is the OIDC client ID
   - **Directory (tenant) ID** — used to construct the issuer URL
4. Go to **Certificates & secrets → New client secret**
   - Create a secret and copy the value (you'll need this for Cognito)
5. Go to **Token configuration → Add optional claim**
   - Add `email`, `preferred_username`, `groups` to the ID token

## Step 2: Configure OIDC Identity Provider in Cognito

Using AWS CLI:

```bash
aws cognito-idp create-identity-provider \
  --user-pool-id <user-pool-id> \
  --provider-name "EntraID" \
  --provider-type "OIDC" \
  --provider-details '{
    "client_id": "<entra-application-client-id>",
    "client_secret": "<entra-client-secret>",
    "authorize_scopes": "openid profile email",
    "oidc_issuer": "https://login.microsoftonline.com/<tenant-id>/v2.0",
    "attributes_request_method": "GET"
  }' \
  --attribute-mapping '{
    "email": "email",
    "username": "sub",
    "custom:team": "custom:department",
    "custom:role": "custom:jobTitle"
  }'
```

## Step 3: Update the Cognito App Client

Add `EntraID` to the list of supported identity providers:

```bash
aws cognito-idp update-user-pool-client \
  --user-pool-id <user-pool-id> \
  --client-id <app-client-id> \
  --supported-identity-providers '["COGNITO", "EntraID"]' \
  --allowed-o-auth-flows '["code"]' \
  --allowed-o-auth-scopes '["openid", "profile", "email"]' \
  --callback-urls '["https://<cloudfront-domain>/callback"]' \
  --logout-urls '["https://<cloudfront-domain>"]' \
  --allowed-o-auth-flows-user-pool-client
```

## Step 4: Test the Integration

1. Open the CloudFront URL in your browser
2. Click **Sign In** — you're redirected to the Cognito Hosted UI
3. The Hosted UI now shows two options:
   - **Sign in with Cognito** (email/password)
   - **Sign in with EntraID** (Microsoft login)
4. Click **Sign in with EntraID**
5. Authenticate with your Microsoft credentials
6. You're redirected back to the Client UI with valid tokens

## Token Claim Mapping

When Entra ID authenticates a user, it returns claims in its ID token. Cognito maps these to its own user attributes:

| Entra ID Claim | Cognito Attribute | Description |
|----------------|-------------------|-------------|
| `sub` | `username` | Unique user identifier |
| `email` | `email` | User's email address |
| `preferred_username` | `preferred_username` | Display name |
| `groups` | (custom mapping) | Entra ID group memberships |
| `department` | `custom:team` | Maps to team attribute |
| `jobTitle` | `custom:role` | Maps to role attribute |

> **Note**: The `custom:team` and `custom:role` mappings depend on your Entra ID tenant having these attributes populated. Adjust the `attribute-mapping` in Step 2 to match your organization's Entra ID schema.

## What Stays the Same

- **Frontend code**: Zero changes. The OAuth2/PKCE flow is identical — the Client UI redirects to Cognito Hosted UI, which now offers Entra ID as an option.
- **Lambda Authorizer**: Still validates Cognito-issued tokens. Cognito issues its own tokens regardless of the upstream IdP.
- **API Gateway**: No changes. It still receives Cognito ID tokens in the Authorization header.
- **Token format**: The ID token is still a Cognito JWT. The `identities` claim indicates the federated provider.

## What Changes

- **User Pool**: Gains an OIDC identity provider configuration
- **App Client**: `supportedIdentityProviders` includes `"EntraID"`
- **Hosted UI**: Automatically shows the Entra ID sign-in button
- **User attributes**: Populated from Entra ID claims via attribute mapping
- **First login**: No forced password change (Entra ID handles authentication)

## Security Considerations

- The Entra ID client secret is stored in Cognito's identity provider configuration (encrypted at rest)
- Consider restricting which Entra ID groups can access the POC using Cognito's pre-authentication Lambda trigger
- Token lifetimes are controlled by Cognito regardless of Entra ID session duration
- Logout from the Client UI signs out of Cognito but not necessarily Entra ID (configure single logout if needed)

## Rollback

To remove Entra ID and revert to Cognito-only:

```bash
# Remove EntraID from supported providers
aws cognito-idp update-user-pool-client \
  --user-pool-id <user-pool-id> \
  --client-id <app-client-id> \
  --supported-identity-providers '["COGNITO"]' \
  --allowed-o-auth-flows '["code"]' \
  --allowed-o-auth-scopes '["openid", "profile", "email"]' \
  --callback-urls '["https://<cloudfront-domain>/callback"]' \
  --logout-urls '["https://<cloudfront-domain>"]' \
  --allowed-o-auth-flows-user-pool-client

# Delete the identity provider
aws cognito-idp delete-identity-provider \
  --user-pool-id <user-pool-id> \
  --provider-name "EntraID"
```
