#!/usr/bin/env python3
"""
setup-agentcore-identity.py — Set up AgentCore Identity for the demo agent.

Creates two things so the agent no longer needs its gateway client secret as a
plaintext environment variable:

  1. A workload identity (`ai-gateway-it-support-agent`) — the agent's identity
     within AgentCore Identity.
  2. A Custom OAuth2 credential provider (`ai-gateway-cognito`) that
     stores the Cognito M2M client_id/secret in the AgentCore token vault and
     mints `client_credentials` tokens for the gateway scope on demand.

At runtime the agent requests the gateway bearer token from the token vault via
this provider, so the secret lives in the vault (AWS Secrets Manager) rather
than in the runtime's environment.

Cognito's OIDC discovery (cognito-idp) does not advertise the client_credentials
token endpoint, so we register explicit authorization-server metadata pointing
at the Hosted UI domain's /oauth2/token endpoint.

Usage:
    python scripts/setup-agentcore-identity.py
"""

import argparse
import json
import os
import sys
from urllib.parse import urlparse

import boto3
from botocore.exceptions import ClientError

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG_FILE = os.path.join(ROOT_DIR, ".agentcore-config.json")

WORKLOAD_IDENTITY_NAME = "ai-gateway-it-support-agent"
OAUTH2_PROVIDER_NAME = "ai-gateway-cognito"


def load_config():
    with open(CONFIG_FILE, encoding="utf-8") as f:
        return json.load(f)


def save_config(cfg):
    with open(CONFIG_FILE, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)
    os.chmod(CONFIG_FILE, 0o600)


def find_user_pool_for_client(cognito, client_id):
    """Find the user pool id that owns the given app client id.

    This is an O(pools × clients) scan and is only used as a fallback when the
    user pool id isn't already known (register-tools.sh now records it in
    .agentcore-config.json, and --user-pool-id can supply it directly).
    """
    paginator = cognito.get_paginator("list_user_pools")
    for page in paginator.paginate(MaxResults=60):
        for pool in page["UserPools"]:
            try:
                cognito.describe_user_pool_client(
                    UserPoolId=pool["Id"], ClientId=client_id
                )
                return pool["Id"]
            except ClientError:
                continue
    return None


def ensure_workload_identity(identity):
    try:
        wi = identity.get_workload_identity(name=WORKLOAD_IDENTITY_NAME)
        print(f"  ⏭️  Workload identity exists: {wi.get('workloadIdentityArn')}")
        return wi["workloadIdentityArn"]
    except ClientError as e:
        if e.response["Error"]["Code"] not in ("ResourceNotFoundException", "ValidationException"):
            raise
    resp = identity.create_workload_identity(name=WORKLOAD_IDENTITY_NAME)
    print(f"  ✅ Created workload identity: {resp.get('workloadIdentityArn')}")
    return resp["workloadIdentityArn"]


def ensure_oauth2_provider(identity, region, user_pool_id, token_endpoint, client_id, client_secret):
    try:
        p = identity.get_oauth2_credential_provider(name=OAUTH2_PROVIDER_NAME)
        print(f"  ⏭️  OAuth2 credential provider exists: {p.get('credentialProviderArn')}")
        return p["credentialProviderArn"]
    except ClientError as e:
        if e.response["Error"]["Code"] not in ("ResourceNotFoundException", "ValidationException"):
            raise

    domain = urlparse(token_endpoint).netloc
    issuer = f"https://cognito-idp.{region}.amazonaws.com/{user_pool_id}"
    authorize_endpoint = f"https://{domain}/oauth2/authorize"

    config = {
        "customOauth2ProviderConfig": {
            "oauthDiscovery": {
                "authorizationServerMetadata": {
                    "issuer": issuer,
                    "authorizationEndpoint": authorize_endpoint,
                    "tokenEndpoint": token_endpoint,
                    "responseTypes": ["code", "token"],
                }
            },
            "clientId": client_id,
            "clientSecret": client_secret,
            "clientAuthenticationMethod": "CLIENT_SECRET_BASIC",
        }
    }

    resp = identity.create_oauth2_credential_provider(
        name=OAUTH2_PROVIDER_NAME,
        credentialProviderVendor="CustomOauth2",
        oauth2ProviderConfigInput=config,
    )
    print(f"  ✅ Created OAuth2 credential provider: {resp.get('credentialProviderArn')}")
    return resp["credentialProviderArn"]


def main():
    ap = argparse.ArgumentParser(description="Set up AgentCore Identity for the demo agent")
    ap.add_argument("--region", default=os.environ.get("AWS_REGION", "us-east-1"))
    ap.add_argument("--user-pool-id", default=None,
                    help="Cognito user pool id (optional; defaults to userPoolId in "
                         ".agentcore-config.json, then a slower account-wide scan)")
    args = ap.parse_args()

    if not os.path.exists(CONFIG_FILE):
        print(f"❌ {CONFIG_FILE} not found. Run scripts/register-tools.sh first.")
        sys.exit(1)

    cfg = load_config()
    region = cfg.get("region", args.region)
    auth = cfg["auth"]
    client_id = auth["clientId"]
    client_secret = auth["clientSecret"]
    token_endpoint = auth["tokenEndpoint"]
    scope = auth["scope"]

    identity = boto3.client("bedrock-agentcore-control", region_name=region)
    cognito = boto3.client("cognito-idp", region_name=region)

    print("=" * 64)
    print("  AgentCore Identity — workload identity + token-vault provider")
    print("=" * 64)

    print("\n▶ Step 1: Resolve Cognito user pool...")
    # Prefer an explicitly supplied id, then the one recorded in config by
    # register-tools.sh; only fall back to the account-wide scan if neither exists.
    user_pool_id = args.user_pool_id or cfg.get("userPoolId")
    if user_pool_id:
        print(f"  ✅ User pool (from {'--user-pool-id' if args.user_pool_id else 'config'}): {user_pool_id}")
    else:
        print("  ℹ️  userPoolId not in config — scanning account for the owning pool...")
        user_pool_id = find_user_pool_for_client(cognito, client_id)
        if not user_pool_id:
            print(f"  ❌ Could not find a user pool owning client {client_id}")
            sys.exit(1)
        print(f"  ✅ User pool: {user_pool_id}")

    print("\n▶ Step 2: Workload identity...")
    workload_arn = ensure_workload_identity(identity)

    print("\n▶ Step 3: OAuth2 credential provider (token vault)...")
    provider_arn = ensure_oauth2_provider(
        identity, region, user_pool_id, token_endpoint, client_id, client_secret
    )

    print("\n▶ Step 4: Saving to .agentcore-config.json...")
    cfg["identity"] = {
        "workloadIdentityName": WORKLOAD_IDENTITY_NAME,
        "workloadIdentityArn": workload_arn,
        "oauth2ProviderName": OAUTH2_PROVIDER_NAME,
        "oauth2ProviderArn": provider_arn,
        "scope": scope,
    }
    save_config(cfg)
    print("  ✅ Saved")

    print("\n" + "=" * 64)
    print("  ✅ AgentCore Identity configured")
    print(f"  Workload identity : {WORKLOAD_IDENTITY_NAME}")
    print(f"  OAuth2 provider   : {OAUTH2_PROVIDER_NAME}")
    print("  The agent can now fetch the gateway token from the token vault")
    print("  (set GATEWAY_OAUTH_PROVIDER) instead of GATEWAY_CLIENT_SECRET.")
    print("=" * 64)


if __name__ == "__main__":
    main()
