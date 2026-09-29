#!/usr/bin/env python3
"""
teardown-agentcore-extras.py — Delete the AgentCore Identity, Memory, and Agent
Registry resources created by the setup-agentcore-*.py / setup-agent-registry.py
scripts. These are billable and are NOT removed by the older cleanup/destroy.sh.

Reads identifiers from .agentcore-config.json. Safe to re-run; missing resources
are skipped.

Usage:
    python scripts/teardown-agentcore-extras.py            # delete all extras
    python scripts/teardown-agentcore-extras.py --only memory
"""

import argparse
import json
import os
import sys

import boto3
from botocore.exceptions import ClientError

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG_FILE = os.path.join(ROOT_DIR, ".agentcore-config.json")


def load_config():
    with open(CONFIG_FILE, encoding="utf-8") as f:
        return json.load(f)


def save_config(cfg):
    with open(CONFIG_FILE, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2)
    os.chmod(CONFIG_FILE, 0o600)


def teardown_registry(ctrl, cfg):
    reg = cfg.get("registry")
    if not reg:
        print("  (no registry in config)")
        return
    rid = reg["registryId"]
    for rec_id in reg.get("records", {}).values():
        try:
            ctrl.delete_registry_record(registryId=rid, recordId=rec_id)
            print(f"  ✅ Deleted registry record {rec_id}")
        except ClientError as e:
            print(f"  ⏭️  record {rec_id}: {e.response['Error']['Code']}")
    try:
        ctrl.delete_registry(registryId=rid)
        print(f"  ✅ Deleted registry {rid}")
    except ClientError as e:
        print(f"  ⏭️  registry {rid}: {e.response['Error']['Code']}")
    cfg.pop("registry", None)


def teardown_memory(ctrl, cfg):
    mem = cfg.get("memory")
    if not mem:
        print("  (no memory in config)")
        return
    mid = mem["memoryId"]
    try:
        ctrl.delete_memory(memoryId=mid)
        print(f"  ✅ Deleted memory {mid}")
    except ClientError as e:
        print(f"  ⏭️  memory {mid}: {e.response['Error']['Code']}")
    cfg.pop("memory", None)


def teardown_identity(ctrl, cfg):
    ident = cfg.get("identity")
    if not ident:
        print("  (no identity in config)")
        return
    try:
        ctrl.delete_oauth2_credential_provider(name=ident["oauth2ProviderName"])
        print(f"  ✅ Deleted OAuth2 provider {ident['oauth2ProviderName']}")
    except ClientError as e:
        print(f"  ⏭️  provider: {e.response['Error']['Code']}")
    try:
        ctrl.delete_workload_identity(name=ident["workloadIdentityName"])
        print(f"  ✅ Deleted workload identity {ident['workloadIdentityName']}")
    except ClientError as e:
        print(f"  ⏭️  workload identity: {e.response['Error']['Code']}")
    cfg.pop("identity", None)


def main():
    ap = argparse.ArgumentParser(description="Delete AgentCore Identity/Memory/Registry extras")
    ap.add_argument("--only", choices=["registry", "memory", "identity"], help="Delete just one group")
    ap.add_argument("--region", default=os.environ.get("AWS_REGION", "us-east-1"))
    args = ap.parse_args()

    if not os.path.exists(CONFIG_FILE):
        print(f"❌ {CONFIG_FILE} not found.")
        sys.exit(1)

    cfg = load_config()
    region = cfg.get("region", args.region)
    ctrl = boto3.client("bedrock-agentcore-control", region_name=region)

    print("=" * 64)
    print("  Tearing down AgentCore extras (Identity / Memory / Registry)")
    print("=" * 64)

    groups = [args.only] if args.only else ["registry", "memory", "identity"]
    if "registry" in groups:
        print("\n▶ Registry...")
        teardown_registry(ctrl, cfg)
    if "memory" in groups:
        print("\n▶ Memory...")
        teardown_memory(ctrl, cfg)
    if "identity" in groups:
        print("\n▶ Identity...")
        teardown_identity(ctrl, cfg)

    save_config(cfg)
    print("\n✅ Done. Updated .agentcore-config.json.")


if __name__ == "__main__":
    main()
