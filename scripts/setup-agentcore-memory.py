#!/usr/bin/env python3
"""
setup-agentcore-memory.py — Create the AgentCore Memory resource used by the
AI Gateway demo agent for cross-session persistence.

Creates (idempotently) a Memory resource with three long-term strategies:
  - userPreference  → /preferences/{actorId}   (learns user/team preferences)
  - semantic        → /facts/{actorId}         (extracts durable facts)
  - summary         → /summaries/{actorId}/{sessionId} (session recaps)

Short-term memory (raw conversation events) is always on; the strategies above
add long-term extraction. The memory id is written to .agentcore-config.json so
the agent and deploy script can pick it up.

Requires boto3/botocore with the bedrock-agentcore-control Memory APIs.

Usage:
    python scripts/setup-agentcore-memory.py
    python scripts/setup-agentcore-memory.py --region us-east-1
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

MEMORY_NAME = "ai_gateway_it_support_memory"
EVENT_EXPIRY_DAYS = 30

STRATEGIES = [
    {
        "userPreferenceMemoryStrategy": {
            "name": "UserPreferences",
            "description": "Learns per-user/per-team IT preferences across sessions.",
            "namespaces": ["/preferences/{actorId}"],
        }
    },
    {
        "semanticMemoryStrategy": {
            "name": "Facts",
            "description": "Extracts durable facts about the user, their org, and recurring issues.",
            "namespaces": ["/facts/{actorId}"],
        }
    },
    {
        "summaryMemoryStrategy": {
            "name": "SessionSummary",
            "description": "Summarizes each support conversation for quick recall.",
            "namespaces": ["/summaries/{actorId}/{sessionId}"],
        }
    },
]


def load_config():
    with open(CONFIG_FILE, encoding="utf-8") as f:
        return json.load(f)


def save_config(cfg):
    with open(CONFIG_FILE, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)
    os.chmod(CONFIG_FILE, 0o600)


def find_memory(ctrl, name):
    token = None
    while True:
        kwargs = {"maxResults": 100}
        if token:
            kwargs["nextToken"] = token
        resp = ctrl.list_memories(**kwargs)
        for m in resp.get("memories", []):
            # list_memories summaries expose id and arn; name match via get if needed.
            mid = m.get("id") or m.get("memoryId")
            if mid and (m.get("name") == name or name in mid):
                return m
        token = resp.get("nextToken")
        if not token:
            return None


def main():
    ap = argparse.ArgumentParser(description="Create AgentCore Memory for the demo agent")
    ap.add_argument("--region", default=os.environ.get("AWS_REGION", "us-east-1"))
    args = ap.parse_args()

    if not os.path.exists(CONFIG_FILE):
        print(f"❌ {CONFIG_FILE} not found. Run scripts/register-tools.sh first.")
        sys.exit(1)

    cfg = load_config()
    region = cfg.get("region", args.region)
    ctrl = boto3.client("bedrock-agentcore-control", region_name=region)

    print("=" * 64)
    print("  AgentCore Memory — setup for AI Gateway demo agent")
    print("=" * 64)

    # Idempotency: reuse existing memory id from config if present and valid.
    existing_id = cfg.get("memory", {}).get("memoryId")
    if existing_id:
        try:
            m = ctrl.get_memory(memoryId=existing_id)["memory"]
            print(f"  ⏭️  Memory already configured ({existing_id}, status={m['status']})")
            _finish(cfg, m, region)
            return
        except ClientError:
            print("  (configured memory id not found — creating a new one)")

    print(f"  Creating memory {MEMORY_NAME} with 3 long-term strategies...")
    try:
        resp = ctrl.create_memory(
            name=MEMORY_NAME,
            description="AI Gateway IT Support Assistant long-term memory",
            eventExpiryDuration=EVENT_EXPIRY_DAYS,
            memoryStrategies=STRATEGIES,
        )
        memory = resp["memory"]
        memory_id = memory.get("id") or memory.get("memoryId")
    except ClientError as e:
        if e.response["Error"]["Code"] in ("ConflictException", "ValidationException") and "exist" in e.response["Error"].get("Message", "").lower():
            found = find_memory(ctrl, MEMORY_NAME)
            if not found:
                raise
            memory_id = found.get("id") or found.get("memoryId")
            print(f"  ⏭️  Reusing existing memory ({memory_id})")
        else:
            raise

    # Poll until ACTIVE.
    print("  Waiting for memory to become ACTIVE (strategies provision in background)...")
    memory = None
    for _ in range(60):
        memory = ctrl.get_memory(memoryId=memory_id)["memory"]
        status = memory["status"]
        if status == "ACTIVE":
            break
        if status in ("FAILED", "CREATE_FAILED"):
            print(f"  ❌ Memory entered {status}: {memory.get('failureReason', '')}")
            sys.exit(1)
        time.sleep(5)  # intentional: poll interval waiting for memory resource to become ACTIVE  # nosemgrep

    # If the poll loop exhausted without reaching ACTIVE, fail rather than
    # persisting a half-provisioned resource that downstream steps assume is ready.
    if memory is None or memory["status"] != "ACTIVE":
        last_status = memory["status"] if memory else "UNKNOWN"
        print(f"  ❌ Memory did not become ACTIVE (last status: {last_status}) after ~300s")
        sys.exit(1)

    print(f"  ✅ Memory status: {memory['status']}  ({memory_id})")

    _finish(cfg, memory, region)


def _finish(cfg, memory, region):
    memory_id = memory.get("id") or memory.get("memoryId")
    cfg["memory"] = {
        "memoryName": MEMORY_NAME,
        "memoryId": memory_id,
        "eventExpiryDays": EVENT_EXPIRY_DAYS,
        "strategies": ["UserPreferences", "Facts", "SessionSummary"],
        "namespaces": {
            "preferences": "/preferences/{actorId}",
            "facts": "/facts/{actorId}",
            "summaries": "/summaries/{actorId}/{sessionId}",
        },
    }
    save_config(cfg)
    print("\n" + "=" * 64)
    print("  ✅ Memory ready and saved to .agentcore-config.json")
    print(f"  Memory ID: {memory_id}")
    print("  Set AGENTCORE_MEMORY_ID for the agent (deploy script injects it).")
    print("=" * 64)


if __name__ == "__main__":
    main()
