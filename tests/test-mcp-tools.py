#!/usr/bin/env python3
"""
test-mcp-tools.py — Validate MCP tool registration and invocation.

Two modes:

  1. Gateway mode (default): connect to the AgentCore Gateway over MCP using a
     Cognito M2M bearer token (read from .agentcore-config.json) and invoke the
     registered tools:
        - search-kb___search_kb
        - create-ticket___create_ticket
     This exercises the real Feature 4 path end-to-end.

  2. Lambda mode (--mode lambda): invoke the two Lambda functions directly via
     the Lambda API. Useful before the gateway exists, or to isolate the tool
     logic from gateway/auth wiring.

Tests:
  1. search_kb     → verify results/count response structure
  2. create_ticket → verify ticket_id (INC...), status, priority, etc.

Usage:
    # Gateway mode (uses .agentcore-config.json):
    python tests/test-mcp-tools.py

    # Explicit config file:
    python tests/test-mcp-tools.py --config .agentcore-config.json

    # Direct Lambda mode (names derived from STACK_NAME env var by default):
    python tests/test-mcp-tools.py --mode lambda --region us-east-1

    # Override Lambda names explicitly (replace 'anycompany' with your --company-name):
    python tests/test-mcp-tools.py --mode lambda \
        --search-kb-name <company>-mcp-tools-<stage>-search-kb \
        --create-ticket-name <company>-mcp-tools-<stage>-create-ticket \
        --region us-east-1
"""

import argparse
import json
import os
import sys
import time

import boto3

SEARCH_QUERY = "tire pressure monitoring system maintenance procedures"
TICKET_PARAMS = {
    "title": "Test Ticket - Automated Validation",
    "priority": "P3",
    "description": "Automated test ticket created by test-mcp-tools.py validation script",
}

DEFAULT_CONFIG = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".agentcore-config.json"
)


# ---------------------------------------------------------------------------
# Response validation (shared by both modes)
# ---------------------------------------------------------------------------
def validate_search_kb_response(response: dict) -> dict:
    checks = {
        "has_results_array": False,
        "results_have_text": False,
        "results_have_score": False,
        "results_have_source": False,
        "count_field_present": False,
    }
    if not isinstance(response, dict) or "error" in response:
        return checks
    results = response.get("results")
    if isinstance(results, list):
        checks["has_results_array"] = True
        if results:
            first = results[0]
            checks["results_have_text"] = bool(first.get("text"))
            checks["results_have_score"] = "score" in first
            checks["results_have_source"] = bool(first.get("source"))
        else:
            # Empty results is a valid shape (0-5 results allowed).
            checks["results_have_text"] = True
            checks["results_have_score"] = True
            checks["results_have_source"] = True
    checks["count_field_present"] = "count" in response
    return checks


def validate_create_ticket_response(response: dict) -> dict:
    checks = {
        "has_ticket_id": False,
        "ticket_id_format": False,
        "has_title": False,
        "has_priority": False,
        "has_status": False,
        "has_created_at": False,
    }
    if not isinstance(response, dict) or "error" in response:
        return checks
    checks["has_ticket_id"] = bool(response.get("ticket_id"))
    checks["has_title"] = bool(response.get("title"))
    checks["has_priority"] = response.get("priority") in ("P1", "P2", "P3", "P4")
    checks["has_status"] = response.get("status") == "created"
    checks["has_created_at"] = bool(response.get("created_at"))
    checks["ticket_id_format"] = str(response.get("ticket_id", "")).startswith("INC")
    return checks


# ---------------------------------------------------------------------------
# Gateway mode — invoke tools over MCP with a Cognito M2M token
# ---------------------------------------------------------------------------
def get_m2m_token(auth: dict) -> str:
    import httpx

    resp = httpx.post(
        auth["tokenEndpoint"],
        data={
            "grant_type": "client_credentials",
            "client_id": auth["clientId"],
            "client_secret": auth["clientSecret"],
            "scope": auth["scope"],
        },
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        timeout=30,
    )
    if resp.status_code != 200:
        raise RuntimeError(f"Token request failed: {resp.status_code} - {resp.text}")
    return resp.json()["access_token"]


def run_gateway_mode(config_path: str) -> bool:
    import asyncio

    from mcp.client.streamable_http import streamablehttp_client
    from mcp import ClientSession

    with open(config_path) as f:
        cfg = json.load(f)

    gateway_url = cfg["gatewayUrl"]
    token = get_m2m_token(cfg["auth"])
    tool_names = cfg.get("tools", [])
    search_tool = next((t for t in tool_names if t.endswith("search_kb")), "search-kb___search_kb")
    ticket_tool = next((t for t in tool_names if t.endswith("create_ticket")), "create-ticket___create_ticket")

    print(f"Gateway URL : {gateway_url}")
    print(f"Tools       : {search_tool}, {ticket_tool}")
    print("==============================================\n")

    all_pass = True

    async def _call_tool_async(name: str, arguments: dict) -> dict:
        """Open an MCP session, call one tool, return parsed JSON content.

        The MCP streamable-HTTP transport and ClientSession are async context
        managers, so this must run on an event loop.
        """
        headers = {"Authorization": f"Bearer {token}"}
        async with streamablehttp_client(gateway_url, headers=headers) as (read, write, _):
            async with ClientSession(read, write) as session:
                await session.initialize()
                result = await session.call_tool(name, arguments=arguments)
                # MCP returns content blocks; tool JSON is in the first text block.
                for block in result.content:
                    text = getattr(block, "text", None)
                    if text:
                        try:
                            return json.loads(text)
                        except json.JSONDecodeError:
                            return {"raw": text}
                return {}

    def call_tool(name: str, arguments: dict) -> dict:
        return asyncio.run(_call_tool_async(name, arguments))

    # --- Test 1: search_kb ---
    print("--- Test 1: Invoke search_kb via gateway ---")
    try:
        search_resp = call_tool(search_tool, {"query": SEARCH_QUERY})
        print(f"  Response: {json.dumps(search_resp, indent=2)[:500]}")
        all_pass &= report_search(validate_search_kb_response(search_resp))
    except Exception as e:  # noqa: BLE001
        print(f"  ❌ FAIL: search_kb invocation error: {e}")
        all_pass = False
    print("")

    # --- Test 2: create_ticket ---
    print("--- Test 2: Invoke create_ticket via gateway ---")
    try:
        ticket_resp = call_tool(ticket_tool, TICKET_PARAMS)
        print(f"  Response: {json.dumps(ticket_resp, indent=2)[:500]}")
        all_pass &= report_ticket(validate_create_ticket_response(ticket_resp))
    except Exception as e:  # noqa: BLE001
        print(f"  ❌ FAIL: create_ticket invocation error: {e}")
        all_pass = False
    print("")

    return all_pass


# ---------------------------------------------------------------------------
# Lambda mode — invoke functions directly (no gateway required)
# ---------------------------------------------------------------------------
def run_lambda_mode(region: str, search_name: str, ticket_name: str) -> bool:
    client = boto3.client("lambda", region_name=region)
    all_pass = True

    def invoke(fn: str, arguments: dict) -> dict:
        # The Lambdas read tool args from event["arguments"].
        payload = json.dumps({"arguments": arguments}).encode()
        resp = client.invoke(FunctionName=fn, Payload=payload)
        body = resp["Payload"].read()
        parsed = json.loads(body) if body else {}
        # Lambdas may wrap errors as {statusCode, body}.
        if isinstance(parsed, dict) and "body" in parsed and "statusCode" in parsed:
            try:
                return json.loads(parsed["body"])
            except (json.JSONDecodeError, TypeError):
                return parsed
        return parsed

    print(f"Region        : {region}")
    print(f"search_kb     : {search_name}")
    print(f"create_ticket : {ticket_name}")
    print("==============================================\n")

    print("--- Test 1: Invoke search_kb Lambda ---")
    try:
        search_resp = invoke(search_name, {"query": SEARCH_QUERY})
        print(f"  Response: {json.dumps(search_resp, indent=2)[:500]}")
        all_pass &= report_search(validate_search_kb_response(search_resp))
    except Exception as e:  # noqa: BLE001
        print(f"  ❌ FAIL: search_kb invocation error: {e}")
        all_pass = False
    print("")

    print("--- Test 2: Invoke create_ticket Lambda ---")
    try:
        ticket_resp = invoke(ticket_name, TICKET_PARAMS)
        print(f"  Response: {json.dumps(ticket_resp, indent=2)[:500]}")
        all_pass &= report_ticket(validate_create_ticket_response(ticket_resp))
    except Exception as e:  # noqa: BLE001
        print(f"  ❌ FAIL: create_ticket invocation error: {e}")
        all_pass = False
    print("")

    return all_pass


# ---------------------------------------------------------------------------
# Reporting helpers
# ---------------------------------------------------------------------------
def _report(checks: dict, labels: dict) -> bool:
    ok = True
    for key, passed in checks.items():
        symbol = "✅ PASS" if passed else "❌ FAIL"
        print(f"{symbol}: {labels[key]}")
        ok &= passed
    return ok


def report_search(checks: dict) -> bool:
    return _report(checks, {
        "has_results_array": "Response contains 'results' array",
        "results_have_text": "Results contain 'text' field",
        "results_have_score": "Results contain 'score' field",
        "results_have_source": "Results contain 'source' field",
        "count_field_present": "Response contains 'count' field",
    })


def report_ticket(checks: dict) -> bool:
    return _report(checks, {
        "has_ticket_id": "Response contains 'ticket_id'",
        "ticket_id_format": "ticket_id starts with 'INC'",
        "has_title": "Response contains 'title'",
        "has_priority": "Response contains valid 'priority'",
        "has_status": "Response 'status' == 'created'",
        "has_created_at": "Response contains 'created_at'",
    })


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def _default_mcp_stack() -> str:
    """Derive the mcp-tools stack name from STACK_NAME env var.

    STACK_NAME is the gateway stack, e.g. 'anycompany-ai-gateway-poc'.
    The mcp-tools stack follows the same company/stage convention:
    'anycompany-mcp-tools-poc'.
    Falls back to 'anycompany-mcp-tools-poc' if STACK_NAME is not set.
    """
    stack = os.environ.get("STACK_NAME", "anycompany-ai-gateway-poc")
    return stack.replace("-ai-gateway-", "-mcp-tools-")


def parse_args():
    mcp_stack = _default_mcp_stack()
    p = argparse.ArgumentParser(description="MCP tools validation test")
    p.add_argument("--mode", choices=["gateway", "lambda"], default="gateway",
                   help="gateway: invoke via AgentCore Gateway (default); lambda: invoke functions directly")
    p.add_argument("--config", default=DEFAULT_CONFIG,
                   help="Path to .agentcore-config.json (gateway mode)")
    p.add_argument("--region", default=os.environ.get("AWS_REGION", "us-east-1"))
    p.add_argument("--search-kb-name", default=f"{mcp_stack}-search-kb",
                   help="search_kb Lambda function name (lambda mode)")
    p.add_argument("--create-ticket-name", default=f"{mcp_stack}-create-ticket",
                   help="create_ticket Lambda function name (lambda mode)")
    return p.parse_args()


def main():
    args = parse_args()

    print("==============================================")
    print(" MCP Tools Test")
    print("==============================================")
    print(f"Mode          : {args.mode}")

    if args.mode == "gateway":
        if not os.path.exists(args.config):
            print(f"❌ ERROR: config file not found: {args.config}")
            print("   Run scripts/register-tools.sh first, or use --mode lambda.")
            sys.exit(1)
        all_pass = run_gateway_mode(args.config)
    else:
        all_pass = run_lambda_mode(args.region, args.search_kb_name, args.create_ticket_name)

    print("==============================================")
    if all_pass:
        print("🎉 OVERALL: PASS — MCP tools validated successfully")
        sys.exit(0)
    else:
        print("💥 OVERALL: FAIL — Some MCP tool checks failed")
        sys.exit(1)


if __name__ == "__main__":
    main()
