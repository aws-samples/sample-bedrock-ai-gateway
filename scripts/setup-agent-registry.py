#!/usr/bin/env python3
"""
setup-agent-registry.py — Publish the AI Gateway POC agent and its MCP tools to
AWS Agent Registry (Amazon Bedrock AgentCore).

AWS Agent Registry is a governed, searchable catalog for agents, tools, MCP
servers, and skills. This script:

  1. Creates (idempotently) a registry `ai-gateway-agent-registry` with
     AWS_IAM inbound auth and auto-approval enabled (POC convenience).
  2. Publishes an MCP record describing the AgentCore Gateway's MCP server and
     its two tools (search_kb, create_ticket).
  3. Publishes an A2A Agent record describing the demo IT Support Assistant.
  4. Waits for both records to reach APPROVED (auto-approval) and, if needed,
     submits/approves them.
  5. Writes registry/record identifiers back into .agentcore-config.json.
  6. Runs a sample semantic search (SearchRegistryRecords) to prove discovery.

Requires boto3/botocore new enough to include the bedrock-agentcore-control
registry APIs (>= ~1.43). The bundled AWS CLI (2.32) does NOT have these yet,
which is why this is a Python script.

Usage:
    python scripts/setup-agent-registry.py
    python scripts/setup-agent-registry.py --region us-east-1
"""

import argparse
import json
import os
import sys
import time

import boto3
from botocore.exceptions import ClientError

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG_FILE = os.path.join(ROOT_DIR, ".agentcore-config.json")
TOOLS_JSON = os.path.join(ROOT_DIR, "config", "gateway-tools.json")

REGISTRY_NAME = "ai-gateway-agent-registry"
MCP_RECORD_NAME = "ai-gateway-it-support-tools"
AGENT_RECORD_NAME = "ai-gateway-it-support-agent"

# Schema versions supported by the registry (see AWS docs: Supported record types).
MCP_SERVER_SCHEMA_VERSION = "2025-12-11"
MCP_TOOLS_PROTOCOL_VERSION = "2025-11-25"
A2A_SCHEMA_VERSION = "0.3"

APPROVED_TERMINAL = {"APPROVED", "REJECTED", "CREATE_FAILED", "UPDATE_FAILED", "DEPRECATED"}


def load_config():
    with open(CONFIG_FILE, encoding="utf-8") as f:
        return json.load(f)


def save_config(cfg):
    with open(CONFIG_FILE, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)
    os.chmod(CONFIG_FILE, 0o600)


def find_registry(ctrl, name):
    token = None
    while True:
        kwargs = {"maxResults": 100}
        if token:
            kwargs["nextToken"] = token
        resp = ctrl.list_registries(**kwargs)
        for r in resp.get("registries", []):
            if r["name"] == name:
                return r
        token = resp.get("nextToken")
        if not token:
            return None


def ensure_registry(ctrl):
    existing = find_registry(ctrl, REGISTRY_NAME)
    if existing:
        print(f"  ⏭️  Registry {REGISTRY_NAME} exists ({existing['registryId']}, status={existing['status']})")
        return wait_registry_ready(ctrl, existing["registryId"])

    print(f"  Creating registry {REGISTRY_NAME} (AWS_IAM auth, auto-approval)...")
    ctrl.create_registry(
        name=REGISTRY_NAME,
        description="AI Gateway POC — governed catalog of agents and MCP tools",
        authorizerType="AWS_IAM",
        approvalConfiguration={"autoApproval": True},
    )
    # CreateRegistry returns only the ARN; resolve the id via list.
    for _ in range(30):
        r = find_registry(ctrl, REGISTRY_NAME)
        if r:
            print(f"  ✅ Created registry ({r['registryId']}, status={r['status']})")
            return wait_registry_ready(ctrl, r["registryId"])
        time.sleep(2)  # intentional: poll interval waiting for registry to appear  # nosemgrep
    raise RuntimeError("Registry did not appear after creation")


def wait_registry_ready(ctrl, registry_id):
    """Wait until a registry is usable (ACTIVE/READY) before adding records."""
    for _ in range(60):
        reg = ctrl.get_registry(registryId=registry_id)
        status = reg["status"]
        if status in ("ACTIVE", "READY"):
            return registry_id
        if status in ("CREATE_FAILED", "FAILED"):
            raise RuntimeError(f"Registry entered {status}: {reg.get('statusReason', '')}")
        print(f"     waiting for registry READY (status={status})...")
        time.sleep(4)  # intentional: poll interval waiting for registry READY status  # nosemgrep
    raise RuntimeError("Registry did not become READY in time")


def find_record(ctrl, registry_id, name):
    token = None
    while True:
        kwargs = {"registryId": registry_id, "maxResults": 100}
        if token:
            kwargs["nextToken"] = token
        resp = ctrl.list_registry_records(**kwargs)
        for r in resp.get("registryRecords", []):
            if r["name"] == name:
                return r
        token = resp.get("nextToken")
        if not token:
            return None


def wait_record(ctrl, registry_id, record_id, label):
    """Poll a record to a terminal status; nudge through the approval flow."""
    submitted = False
    for _ in range(60):
        rec = ctrl.get_registry_record(registryId=registry_id, recordId=record_id)
        status = rec["status"]
        if status == "APPROVED":
            print(f"  ✅ {label}: APPROVED")
            return rec
        if status in ("CREATE_FAILED", "UPDATE_FAILED", "REJECTED"):
            print(f"  ❌ {label}: {status} — {rec.get('statusReason', '')}")
            return rec
        if status == "PENDING_APPROVAL" and not submitted:
            # Auto-approval should clear this; submit explicitly to be safe.
            try:
                ctrl.submit_registry_record_for_approval(registryId=registry_id, recordId=record_id)
            except ClientError as e:
                # Already submitted / not applicable is fine.
                if e.response["Error"]["Code"] not in ("ValidationException", "ConflictException"):
                    raise
            submitted = True
        if status == "DRAFT":
            try:
                ctrl.submit_registry_record_for_approval(registryId=registry_id, recordId=record_id)
                submitted = True
            except ClientError:
                pass
        time.sleep(3)  # intentional: poll interval waiting for record approval  # nosemgrep
    print(f"  ⚠️  {label}: did not reach APPROVED in time (last status={status})")
    return rec


def ensure_mcp_record(ctrl, registry_id, gateway_url):
    existing = find_record(ctrl, registry_id, MCP_RECORD_NAME)
    if existing:
        print(f"  ⏭️  MCP record {MCP_RECORD_NAME} exists ({existing['recordId']}, status={existing['status']})")
        return existing["recordId"]

    with open(TOOLS_JSON, encoding="utf-8") as f:
        tools_cfg = json.load(f)
    tools = [
        {"name": t["name"], "description": t["description"], "inputSchema": t["inputSchema"]}
        for t in tools_cfg["tools"]
    ]

    server_descriptor = {
        "name": "ai-gateway/it-support-mcp",
        "description": "AI Gateway IT support MCP server: KB search and incident ticket creation.",
        "version": "1.0.0",
        "websiteUrl": gateway_url or "https://example.com",
    }
    tools_descriptor = {"tools": tools}

    print(f"  Publishing MCP record {MCP_RECORD_NAME} ({len(tools)} tools)...")
    resp = ctrl.create_registry_record(
        registryId=registry_id,
        name=MCP_RECORD_NAME,
        description="AgentCore Gateway MCP tools: search_kb, create_ticket",
        descriptorType="MCP",
        recordVersion="1.0.0",
        descriptors={
            "mcp": {
                "server": {
                    "schemaVersion": MCP_SERVER_SCHEMA_VERSION,
                    "inlineContent": json.dumps(server_descriptor),
                },
                "tools": {
                    "protocolVersion": MCP_TOOLS_PROTOCOL_VERSION,
                    "inlineContent": json.dumps(tools_descriptor),
                },
            }
        },
    )
    record_id = resp["recordArn"].split("/")[-1]
    print(f"  ✅ Created MCP record (status={resp['status']})")
    return record_id


def ensure_agent_record(ctrl, registry_id, cfg):
    existing = find_record(ctrl, registry_id, AGENT_RECORD_NAME)
    if existing:
        print(f"  ⏭️  Agent record {AGENT_RECORD_NAME} exists ({existing['recordId']}, status={existing['status']})")
        return existing["recordId"]

    runtime_arn = cfg.get("agentRuntimeArn", "")
    # A2A AgentCard (schema 0.3). url points at the deployed runtime ARN as the
    # logical endpoint; AgentCore Runtime is invoked via the bedrock-agentcore API.
    agent_card = {
        "name": "AI Gateway IT Support Assistant",
        "description": "Strands agent on AgentCore Runtime that answers IT questions "
                       "by searching the knowledge base and files incident "
                       "tickets, using MCP tools via AgentCore Gateway.",
        "version": "1.0.0",
        "protocolVersion": "0.3.0",
        "url": runtime_arn or "arn:aws:bedrock-agentcore:us-east-1::runtime/ai_gateway_demo_agent",
        "capabilities": {},
        "defaultInputModes": ["text/plain"],
        "defaultOutputModes": ["text/plain"],
        "skills": [
            {
                "id": "kb-search",
                "name": "Knowledge Base Search",
                "description": "Search the AI Gateway IT knowledge base for runbooks, "
                               "TPMS docs, network and incident-response guidance.",
                "tags": ["it-support", "knowledge-base", "search", "rag"],
            },
            {
                "id": "ticket-creation",
                "name": "Incident Ticket Creation",
                "description": "Create prioritized (P1-P4) incident tickets for IT issues.",
                "tags": ["it-support", "incident", "servicenow", "ticketing"],
            },
        ],
    }

    print(f"  Publishing A2A Agent record {AGENT_RECORD_NAME}...")
    resp = ctrl.create_registry_record(
        registryId=registry_id,
        name=AGENT_RECORD_NAME,
        description="AI Gateway IT Support Assistant (AgentCore Runtime, Strands).",
        descriptorType="A2A",
        recordVersion="1.0.0",
        descriptors={
            "a2a": {
                "agentCard": {
                    "schemaVersion": A2A_SCHEMA_VERSION,
                    "inlineContent": json.dumps(agent_card),
                }
            }
        },
    )
    record_id = resp["recordArn"].split("/")[-1]
    print(f"  ✅ Created Agent record (status={resp['status']})")
    return record_id


def demo_search(region, registry_id):
    data = boto3.client("bedrock-agentcore", region_name=region)
    queries = ["create an incident ticket", "search internal documentation"]
    print("\n▶ Sample discovery via SearchRegistryRecords:")
    for q in queries:
        try:
            resp = data.search_registry_records(
                searchQuery=q, registryIds=[registry_id], maxResults=5
            )
        except ClientError as e:
            print(f"  ⚠️  search '{q}' failed: {e.response['Error']['Code']} — {e.response['Error'].get('Message','')}")
            continue
        records = resp.get("registryRecords", resp.get("results", []))
        print(f"  query: \"{q}\" → {len(records)} result(s)")
        for r in records:
            name = r.get("name", "?")
            dtype = r.get("descriptorType", "?")
            print(f"      • [{dtype}] {name}")


def main():
    ap = argparse.ArgumentParser(description="Publish agent + MCP tools to AWS Agent Registry")
    ap.add_argument("--region", default=os.environ.get("AWS_REGION", "us-east-1"))
    args = ap.parse_args()

    if not os.path.exists(CONFIG_FILE):
        print(f"❌ {CONFIG_FILE} not found. Run scripts/register-tools.sh first.")
        sys.exit(1)

    cfg = load_config()
    region = cfg.get("region", args.region)
    gateway_url = cfg.get("gatewayUrl", "")

    ctrl = boto3.client("bedrock-agentcore-control", region_name=region)

    print("=" * 64)
    print("  AWS Agent Registry — publish AI Gateway agent + MCP tools")
    print("=" * 64)

    print("\n▶ Step 1: Registry...")
    registry_id = ensure_registry(ctrl)

    print("\n▶ Step 2: MCP tools record...")
    mcp_record_id = ensure_mcp_record(ctrl, registry_id, gateway_url)

    print("\n▶ Step 3: A2A Agent record...")
    agent_record_id = ensure_agent_record(ctrl, registry_id, cfg)

    print("\n▶ Step 4: Waiting for records to be APPROVED...")
    wait_record(ctrl, registry_id, mcp_record_id, "MCP tools record")
    wait_record(ctrl, registry_id, agent_record_id, "Agent record")

    print("\n▶ Step 5: Writing registry details to .agentcore-config.json...")
    cfg["registry"] = {
        "registryName": REGISTRY_NAME,
        "registryId": registry_id,
        "records": {
            "mcpToolsRecordId": mcp_record_id,
            "agentRecordId": agent_record_id,
        },
    }
    save_config(cfg)
    print("  ✅ Saved")

    demo_search(region, registry_id)

    print("\n" + "=" * 64)
    print("  ✅ Agent Registry populated")
    print(f"  Registry: {REGISTRY_NAME} ({registry_id})")
    print("  Records:  ai-gateway-it-support-tools (MCP), ai-gateway-it-support-agent (A2A)")
    print("=" * 64)


if __name__ == "__main__":
    main()
