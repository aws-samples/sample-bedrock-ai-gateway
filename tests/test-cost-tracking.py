#!/usr/bin/env python3
"""
test-cost-tracking.py — Validate token usage and cost tracking in CloudWatch.

Makes 50 model invocations through the gateway, then queries CloudWatch Logs
to verify that token usage data (input tokens, output tokens, model ID) is
recorded within 5 minutes.

Usage:
    python tests/test-cost-tracking.py --gateway-url <URL> --api-key <KEY> --region <REGION>

Environment variables (alternative):
    GATEWAY_URL  — API Gateway endpoint
    API_KEY      — API key for the usage plan
    AWS_REGION   — AWS region (default: us-east-1)
"""

import argparse
import json
import os
import sys
import time

import boto3
import requests

###############################################################################
# Configuration
###############################################################################
TOTAL_INVOCATIONS = 50
MAX_WAIT_SECONDS = 300  # 5 minutes
POLL_INTERVAL_SECONDS = 30
LOG_GROUP_PREFIX = "/aws/bedrock"
CONVERSE_PATH = "/model/us.anthropic.claude-sonnet-4-6/converse-stream"

PAYLOAD = {
    "modelId": "us.anthropic.claude-sonnet-4-6",
    "messages": [{"role": "user", "content": [{"text": "Say hello in one word."}]}],
}


###############################################################################
# Helpers
###############################################################################
def parse_args():
    parser = argparse.ArgumentParser(description="Cost tracking validation test")
    parser.add_argument("--gateway-url", default=os.environ.get("GATEWAY_URL"),
                        help="API Gateway URL (or set GATEWAY_URL env var)")
    parser.add_argument("--api-key", default=os.environ.get("API_KEY"),
                        help="API key (or set API_KEY env var)")
    parser.add_argument("--user-pool-id", default=os.environ.get("USER_POOL_ID"),
                        help="Cognito User Pool ID")
    parser.add_argument("--test-client-id", default=os.environ.get("TEST_CLIENT_ID"),
                        help="Test App Client ID (from create-test-client.sh)")
    parser.add_argument("--username", default=os.environ.get("USERNAME"),
                        help="Cognito username (email)")
    parser.add_argument("--password", default=os.environ.get("PASSWORD"),
                        help="Cognito password")
    parser.add_argument("--region", default=os.environ.get("AWS_REGION", "us-east-1"),
                        help="AWS region (default: us-east-1)")
    return parser.parse_args()


def send_invocations(gateway_url: str, api_key: str, auth_token: str, count: int) -> dict:
    """Send model invocations and return success/failure counts."""
    endpoint = f"{gateway_url}{CONVERSE_PATH}"
    headers = {
        "Content-Type": "application/json",
        "x-api-key": api_key,
        "Authorization": f"Bearer {auth_token}",
    }

    results = {"success": 0, "failed": 0, "rate_limited": 0}

    for i in range(1, count + 1):
        try:
            resp = requests.post(endpoint, json=PAYLOAD, headers=headers, timeout=30)
            if resp.status_code == 200:
                results["success"] += 1
            elif resp.status_code == 429:
                results["rate_limited"] += 1
                time.sleep(2)  # Back off on rate limit
            else:
                results["failed"] += 1
        except requests.RequestException:
            results["failed"] += 1

        if i % 10 == 0:
            print(f"  Sent {i}/{count} — success: {results['success']}, "
                  f"rate_limited: {results['rate_limited']}, failed: {results['failed']}")

        # Small delay to avoid overwhelming the gateway
        time.sleep(0.5)

    return results


def find_log_group(logs_client: object) -> str:
    """Find the Bedrock model invocation log group."""
    paginator = logs_client.get_paginator("describe_log_groups")
    for page in paginator.paginate(logGroupNamePrefix=LOG_GROUP_PREFIX):
        for group in page.get("logGroups", []):
            name = group["logGroupName"]
            if "invocation" in name.lower() or "modelinvocation" in name.lower():
                return name

    # Fallback: return first matching group
    for page in paginator.paginate(logGroupNamePrefix=LOG_GROUP_PREFIX):
        for group in page.get("logGroups", []):
            return group["logGroupName"]

    return ""


def query_cloudwatch_for_tokens(logs_client: object, log_group: str, start_time: int) -> dict:
    """Query CloudWatch Logs Insights for token usage data."""
    query = """
    fields @timestamp, @message
    | filter @message like /inputTokens/ or @message like /input_tokens/
    | limit 20
    """

    response = logs_client.start_query(
        logGroupName=log_group,
        startTime=start_time,
        endTime=int(time.time()),
        queryString=query,
    )

    query_id = response["queryId"]

    # Poll for results
    while True:
        result = logs_client.get_query_results(queryId=query_id)
        status = result["status"]
        if status in ("Complete", "Failed", "Cancelled"):
            break
        time.sleep(5)

    return result


def validate_token_data(result: dict) -> dict:
    """Check if query results contain expected token fields."""
    findings = {
        "has_input_tokens": False,
        "has_output_tokens": False,
        "has_model_id": False,
        "record_count": len(result.get("results", [])),
    }

    for record in result.get("results", []):
        message = ""
        for field in record:
            if field["field"] == "@message":
                message = field["value"]
                break

        if not message:
            continue

        # Check for token fields (various formats)
        lower_msg = message.lower()
        if "inputtokens" in lower_msg or "input_tokens" in lower_msg:
            findings["has_input_tokens"] = True
        if "outputtokens" in lower_msg or "output_tokens" in lower_msg:
            findings["has_output_tokens"] = True
        if "modelid" in lower_msg or "model_id" in lower_msg or "anthropic.claude" in lower_msg:
            findings["has_model_id"] = True

    return findings


###############################################################################
# Main
###############################################################################
def main():
    args = parse_args()

    if not args.gateway_url:
        print("❌ ERROR: --gateway-url or GATEWAY_URL env var required")
        sys.exit(1)
    if not args.api_key:
        print("❌ ERROR: --api-key or API_KEY env var required")
        sys.exit(1)
    if not args.user_pool_id or not args.test_client_id or not args.username or not args.password:
        print("❌ ERROR: --user-pool-id, --test-client-id, --username, --password required")
        print("   (Or set USER_POOL_ID, TEST_CLIENT_ID, USERNAME, PASSWORD env vars)")
        sys.exit(1)

    print("==============================================")
    print(" Cost Tracking Test")
    print("==============================================")
    print(f"Gateway URL : {args.gateway_url}")
    print(f"Region      : {args.region}")
    print(f"Invocations : {TOTAL_INVOCATIONS}")
    print(f"Max wait    : {MAX_WAIT_SECONDS}s for CloudWatch data")
    print("==============================================\n")

    # Step 0: Obtain auth token
    print("Step 0: Obtaining auth token via test client...")
    cognito = boto3.client("cognito-idp", region_name=args.region)
    try:
        auth_result = cognito.admin_initiate_auth(
            UserPoolId=args.user_pool_id,
            ClientId=args.test_client_id,
            AuthFlow="ADMIN_NO_SRP_AUTH",
            AuthParameters={
                "USERNAME": args.username,
                "PASSWORD": args.password,
            },
        )
        auth_token = auth_result["AuthenticationResult"]["IdToken"]
        print("  ✅ Token obtained\n")
    except Exception as e:
        print(f"❌ FAIL: Could not obtain auth token: {e}")
        sys.exit(1)

    # Step 1: Send invocations
    print("Step 1: Sending model invocations...")
    invocation_start = int(time.time())
    results = send_invocations(args.gateway_url, args.api_key, auth_token, TOTAL_INVOCATIONS)
    print(f"\n  Results: {results}\n")

    if results["success"] == 0:
        print("❌ FAIL: No successful invocations — cannot verify cost tracking")
        sys.exit(1)

    # Step 2: Wait for CloudWatch data
    print("Step 2: Waiting for CloudWatch data to appear...")
    logs_client = boto3.client("logs", region_name=args.region)

    log_group = find_log_group(logs_client)
    if not log_group:
        print("❌ FAIL: No Bedrock invocation log group found in CloudWatch")
        sys.exit(1)

    print(f"  Found log group: {log_group}")

    # Poll CloudWatch until data appears or timeout
    elapsed = 0
    findings = None

    while elapsed < MAX_WAIT_SECONDS:
        print(f"  Querying CloudWatch... (elapsed: {elapsed}s)")
        result = query_cloudwatch_for_tokens(logs_client, log_group, invocation_start)
        findings = validate_token_data(result)

        if findings["record_count"] > 0:
            print(f"  Found {findings['record_count']} records with token data")
            break

        time.sleep(POLL_INTERVAL_SECONDS)
        elapsed += POLL_INTERVAL_SECONDS

    # Step 3: Validate results
    print("\n==============================================")
    print(" Results")
    print("==============================================")

    if findings is None or findings["record_count"] == 0:
        print("❌ FAIL: No token usage data found in CloudWatch within 5 minutes")
        sys.exit(1)

    all_pass = True

    if findings["has_input_tokens"]:
        print("✅ PASS: Input token count found in CloudWatch logs")
    else:
        print("❌ FAIL: Input token count NOT found in CloudWatch logs")
        all_pass = False

    if findings["has_output_tokens"]:
        print("✅ PASS: Output token count found in CloudWatch logs")
    else:
        print("❌ FAIL: Output token count NOT found in CloudWatch logs")
        all_pass = False

    if findings["has_model_id"]:
        print("✅ PASS: Model ID found in CloudWatch logs")
    else:
        print("❌ FAIL: Model ID NOT found in CloudWatch logs")
        all_pass = False

    print(f"\n  Total records found: {findings['record_count']}")
    print(f"  Successful invocations: {results['success']}")

    print("")
    if all_pass:
        print("🎉 OVERALL: PASS — Cost tracking data verified in CloudWatch")
        sys.exit(0)
    else:
        print("💥 OVERALL: FAIL — Some cost tracking data missing")
        sys.exit(1)


if __name__ == "__main__":
    main()
