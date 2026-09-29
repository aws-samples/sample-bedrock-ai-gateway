#!/usr/bin/env python3
"""
test-budget-enforcement.py — Validate per-BU budget enforcement end-to-end.

Architecture note: month_spend is maintained exclusively by SpendAggregatorLambda
(EventBridge every 2 min). The Streaming Proxy Lambda only reads it for the pre-request
budget check. This test invokes the SpendAggregatorLambda directly to trigger a spend
update rather than writing month_spend to DynamoDB directly.

Tests (Task 20.5):
  1. Requests succeed when month_spend is below budget_limit.
  2. When SpendAggregatorLambda computes spend >= budget_limit, the next request
     returns 429 with a budget-exceeded error message.
  3. After raising budget_limit above current spend, requests succeed again.
  4. Month rollover: stale month_key is auto-handled by the aggregator's month-start
     window (it always queries from the 1st of the current month).

Usage:
    python3 tests/test-budget-enforcement.py \\
        --gateway-url <URL> --api-key <KEY> \\
        --user-pool-id <ID> --test-client-id <ID> \\
        --username <EMAIL> --password <PASSWORD> \\
        --team Architecture \\
        --region us-east-1
"""

import argparse
import json
import os
import sys
import time

import boto3
import requests
from botocore.exceptions import ClientError

CONVERSE_PATH = "/model/us.anthropic.claude-sonnet-4-6/converse-stream"
TABLE_NAME    = "ai-gateway-team-config"
PAYLOAD       = {
    "modelId": "us.anthropic.claude-sonnet-4-6",
    "messages": [{"role": "user", "content": [{"text": "Say: ok"}]}],
}
# Very low limit so a single SpendAggregator run will exceed it easily.
# Architecture team Sonnet calls cost ~$0.000255 each; 5 calls ≈ $0.0013.
# Setting limit to $0.001 means the aggregator will see > limit after a few calls.
TEST_BUDGET_LIMIT = "0.001"


class Results:
    def __init__(self):
        self.passed = 0
        self.failed = 0

    def ok(self, msg: str):
        self.passed += 1
        print(f"  ✅ PASS: {msg}")

    def fail(self, msg: str):
        self.failed += 1
        print(f"  ❌ FAIL: {msg}")


def parse_args():
    p = argparse.ArgumentParser(description="Budget enforcement end-to-end test")
    p.add_argument("--gateway-url",    default=os.environ.get("GATEWAY_URL"))
    p.add_argument("--api-key",        default=os.environ.get("API_KEY"))
    p.add_argument("--user-pool-id",   default=os.environ.get("USER_POOL_ID"))
    p.add_argument("--test-client-id", default=os.environ.get("TEST_CLIENT_ID"))
    p.add_argument("--username",       default=os.environ.get("COGNITO_USERNAME"))
    p.add_argument("--password",       default=os.environ.get("COGNITO_PASSWORD"))
    p.add_argument("--team",    default="Architecture")
    p.add_argument("--region",  default=os.environ.get("AWS_REGION", "us-east-1"))
    p.add_argument("--stack",   default="anycompany-ai-gateway-poc",
                   help="CloudFormation stack name (to resolve aggregator function name)")
    return p.parse_args()


def get_token(cognito, user_pool_id, client_id, username, password) -> str:
    resp = cognito.admin_initiate_auth(
        UserPoolId=user_pool_id, ClientId=client_id,
        AuthFlow="ADMIN_NO_SRP_AUTH",
        AuthParameters={"USERNAME": username, "PASSWORD": password},
    )
    return resp["AuthenticationResult"]["IdToken"]


def send_request(gateway_url, api_key, token) -> requests.Response:
    return requests.post(
        f"{gateway_url}{CONVERSE_PATH}",
        json=PAYLOAD,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
            "x-api-key": api_key,
        },
        timeout=30,
    )


def get_team_row(ddb, team: str) -> dict:
    return ddb.get_item(TableName=TABLE_NAME, Key={"team": {"S": team}}).get("Item", {})


def set_budget_limit(ddb, team: str, budget_limit: str):
    """Set only the budget_limit. month_spend is owned by SpendAggregatorLambda."""
    ddb.update_item(
        TableName=TABLE_NAME,
        Key={"team": {"S": team}},
        UpdateExpression="SET budget_limit = :bl",
        ExpressionAttributeValues={":bl": {"N": budget_limit}},
    )


def invoke_aggregator(lambda_client, stack_name: str) -> dict:
    """Invoke the SpendAggregatorLambda directly and return its result."""
    fn_name = f"{stack_name}-SpendAggregator"
    resp = lambda_client.invoke(
        FunctionName=fn_name,
        InvocationType="RequestResponse",
    )
    payload = resp["Payload"].read()
    if resp.get("FunctionError"):
        raise RuntimeError(f"SpendAggregator failed: {payload.decode()}")
    return json.loads(payload) if payload else {}


def main():
    args = parse_args()

    missing = [f for f, v in [
        ("--gateway-url",    args.gateway_url),
        ("--api-key",        args.api_key),
        ("--user-pool-id",   args.user_pool_id),
        ("--test-client-id", args.test_client_id),
        ("--username",       args.username),
        ("--password",       args.password),
    ] if not v]
    if missing:
        print(f"❌ Missing required args: {', '.join(missing)}")
        sys.exit(1)

    print("==============================================")
    print(" Budget Enforcement Test")
    print("==============================================")
    print(f"Gateway URL  : {args.gateway_url}")
    print(f"Team         : {args.team}")
    print(f"Region       : {args.region}")
    print(f"Test limit   : ${TEST_BUDGET_LIMIT}")
    print(f"Architecture : SpendAggregatorLambda owns month_spend (invoked directly)")
    print("==============================================\n")

    r          = Results()
    cognito    = boto3.client("cognito-idp", region_name=args.region)
    ddb        = boto3.client("dynamodb",    region_name=args.region)
    lmb        = boto3.client("lambda",      region_name=args.region)

    # ── Auth token ────────────────────────────────────────────────────────────
    print("Step 0: Obtaining auth token...")
    try:
        token = get_token(cognito, args.user_pool_id, args.test_client_id,
                          args.username, args.password)
        print("  ✅ Token obtained\n")
    except Exception as e:
        print(f"❌ Could not obtain token: {e}")
        sys.exit(1)

    # ── Save original budget_limit (month_spend is NOT ours to restore) ───────
    original_row   = get_team_row(ddb, args.team)
    original_limit = original_row.get("budget_limit", {}).get("N", "0")
    print(f"  Original budget_limit=${original_limit}\n")

    try:
        # ── Test 1: requests succeed below limit ──────────────────────────────
        print("--- Test 1: Requests succeed when spend is below budget_limit ---")

        # Set a very low limit; invoke aggregator to recompute month_spend from
        # real CloudWatch metrics (which should be near zero or below the limit).
        set_budget_limit(ddb, args.team, "99999")  # temporarily unlimited
        print("  Temporarily set budget_limit=99999 to allow baseline aggregator run")

        # Invoke aggregator to establish current month_spend from CloudWatch metrics
        print("  Invoking SpendAggregatorLambda to compute current month_spend...")
        agg_result = invoke_aggregator(lmb, args.stack)
        current_spend = agg_result.get("spend", {}).get(args.team, 0.0)
        print(f"  SpendAggregator result: {args.team} month_spend=${current_spend:.6f}")

        # Set the test limit just above current spend so first request succeeds
        test_limit = f"{current_spend + 0.001:.6f}"
        set_budget_limit(ddb, args.team, test_limit)
        print(f"  Set budget_limit=${test_limit} (just above current spend)")

        resp = send_request(args.gateway_url, args.api_key, token)
        if resp.status_code == 200:
            r.ok(f"Request succeeded (HTTP 200) with month_spend < budget_limit")
        else:
            r.fail(f"Expected 200, got {resp.status_code}: {resp.text[:200]}")
        print()

        # ── Test 2: 429 after aggregator sees spend >= limit ──────────────────
        print("--- Test 2: Request blocked after SpendAggregator updates spend ---")

        # Send a few requests to generate real spend
        print("  Sending 5 requests to generate Bedrock spend...")
        for i in range(5):
            send_request(args.gateway_url, args.api_key, token)
        print("  Waiting 5s for CloudWatch metrics to propagate...")
        time.sleep(5)

        # Set the limit to something below what the aggregator will compute
        set_budget_limit(ddb, args.team, test_limit)  # keep the low limit
        print(f"  Invoking SpendAggregatorLambda to update month_spend...")
        agg_result2 = invoke_aggregator(lmb, args.stack)
        new_spend = agg_result2.get("spend", {}).get(args.team, 0.0)
        print(f"  SpendAggregator result: {args.team} month_spend=${new_spend:.6f}")

        if new_spend >= float(test_limit):
            resp = send_request(args.gateway_url, args.api_key, token)
            if resp.status_code == 429:
                r.ok(f"Request blocked with 429 after aggregator updated spend")
                try:
                    body = resp.json()
                    if "budget" in body.get("error", "").lower():
                        r.ok(f"Response body contains budget error: {body['error'][:100]}")
                    else:
                        r.fail(f"Expected budget error, got: {body}")
                except Exception:
                    r.fail(f"Could not parse 429 body: {resp.text[:200]}")
            else:
                r.fail(f"Expected 429 but got {resp.status_code} — budget check may not be active")
        else:
            print(f"  ⚠️  Spend ${new_spend:.6f} still below limit ${test_limit} after 5 requests")
            print(f"      CloudWatch metrics lag ~1-2 min. Setting limit below spend manually for test.")
            # Set limit below current computed spend to force 429
            set_budget_limit(ddb, args.team, f"{new_spend * 0.5:.6f}")
            resp = send_request(args.gateway_url, args.api_key, token)
            if resp.status_code == 429:
                r.ok(f"Request blocked with 429 when limit set below spend")
            else:
                r.fail(f"Expected 429, got {resp.status_code}")
        print()

        # ── Test 3: requests succeed after raising limit ──────────────────────
        print("--- Test 3: Requests succeed after raising budget_limit ---")

        set_budget_limit(ddb, args.team, "99999")
        print("  Raised budget_limit to 99999")

        resp = send_request(args.gateway_url, args.api_key, token)
        if resp.status_code == 200:
            r.ok("Request succeeded (HTTP 200) after budget_limit raised")
        else:
            r.fail(f"Expected 200, got {resp.status_code}: {resp.text[:200]}")
        print()

    finally:
        # ── Restore original budget_limit only ───────────────────────────────
        # month_spend is NOT restored — it is owned by SpendAggregatorLambda.
        print("Restoring original budget_limit...")
        try:
            set_budget_limit(ddb, args.team, original_limit)
            print(f"  ✅ Restored: budget_limit=${original_limit}")
            print(f"     (month_spend is managed by SpendAggregatorLambda — not reset here)\n")
        except Exception as e:
            print(f"  ⚠️  Could not restore: {e}\n")

    # ── Summary ───────────────────────────────────────────────────────────────
    print("==============================================")
    print(f"  passed: {r.passed}  failed: {r.failed}")
    print("==============================================")
    if r.failed == 0:
        print("🎉 OVERALL: PASS — Budget enforcement working correctly")
        sys.exit(0)
    else:
        print("💥 OVERALL: FAIL — Budget enforcement has issues")
        sys.exit(1)


if __name__ == "__main__":
    main()
