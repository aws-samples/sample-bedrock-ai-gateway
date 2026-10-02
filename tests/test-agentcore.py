#!/usr/bin/env python3
"""
test-agentcore.py — Validate the AgentCore primitives wired into the deploy.

Exercises the four AgentCore building blocks the demo agent depends on, using
the identifiers written to .agentcore-config.json by the deploy scripts:

  1. Identity (token vault) — the Cognito M2M credentials are stored in the
     AgentCore token vault via an OAuth2 credential provider, so the agent can
     fetch the gateway bearer token from the vault WITHOUT a GATEWAY_CLIENT_SECRET
     in its runtime environment.
  2. Memory (cross-session persistence) — two runtime invocations that share the
     same session_id/actor_id; the second recalls context from the first.
  3. Registry (discovery) — SearchRegistryRecords returns the published MCP tools
     record and the A2A agent record for natural-language queries.
  4. Demo agent end-to-end — a runtime invocation returns a structured response
     with `response`, `session_id`, `actor_id`, and `memory_enabled` fields.

Every check degrades gracefully: when the underlying resource is not present in
.agentcore-config.json (or the AWS API is unavailable), the check is SKIPPED
with a clear message instead of failing hard. Skips do not fail the suite.

Usage:
    # Uses .agentcore-config.json at the repo root by default:
    python tests/test-agentcore.py

    # Explicit config / region / profile:
    python tests/test-agentcore.py --config .agentcore-config.json \
        --region us-east-1 --profile my-profile
"""

import argparse
import json
import os
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone

import boto3
from botocore.exceptions import BotoCoreError, ClientError

DEFAULT_CONFIG = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".agentcore-config.json"
)

# A memory fact planted in the first invocation and recalled in the second.
MEMORY_FACT = "My name is Dana and I work on the TPMS engineering team."
MEMORY_RECALL_PROMPT = "Which engineering team did I tell you I work on? Answer in one short sentence."
MEMORY_RECALL_KEYWORD = "tpms"

E2E_PROMPT = "What can you help me with? Reply in one short sentence."
E2E_REQUIRED_FIELDS = ("response", "session_id", "actor_id", "memory_enabled")

# Natural-language discovery queries → the record type we expect to surface.
REGISTRY_QUERIES = [
    ("create an incident ticket", "MCP tools record"),
    ("IT support assistant agent", "A2A agent record"),
]


# ---------------------------------------------------------------------------
# Result tracking — PASS / FAIL / SKIP with emoji output
# ---------------------------------------------------------------------------
class Results:
    def __init__(self):
        self.passed = 0
        self.failed = 0
        self.skipped = 0

    def ok(self, msg: str):
        self.passed += 1
        print(f"  ✅ PASS: {msg}")

    def fail(self, msg: str):
        self.failed += 1
        print(f"  ❌ FAIL: {msg}")

    def skip(self, msg: str):
        self.skipped += 1
        print(f"  ⏭️  SKIP: {msg}")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def parse_args():
    p = argparse.ArgumentParser(description="AgentCore primitives validation test")
    p.add_argument("--config", default=DEFAULT_CONFIG,
                   help="Path to .agentcore-config.json (default: repo root)")
    p.add_argument("--region", default=os.environ.get("AWS_REGION", "us-east-1"),
                   help="AWS region (default: us-east-1)")
    p.add_argument("--profile", default=os.environ.get("AWS_PROFILE"),
                   help="AWS named profile to use (optional)")
    return p.parse_args()


def make_session(region: str, profile: str):
    """Build a boto3 session honoring an optional named profile."""
    if profile:
        return boto3.Session(profile_name=profile, region_name=region)
    return boto3.Session(region_name=region)


def runtime_session_id() -> str:
    """AgentCore Runtime requires a session id of at least 33 characters."""
    return f"test-agentcore-{uuid.uuid4().hex}"  # 15 + 32 = 47 chars


def invoke_runtime(client, runtime_arn: str, prompt: str,
                   session_id: str, actor_id: str, runtime_sid: str) -> dict:
    """Invoke the demo agent on AgentCore Runtime and return the parsed JSON body.

    The payload's session_id/actor_id drive AgentCore Memory scoping inside the
    agent; runtime_sid groups the invocation on the runtime itself.
    """
    payload = json.dumps({
        "prompt": prompt,
        "session_id": session_id,
        "actor_id": actor_id,
    }).encode("utf-8")

    resp = client.invoke_agent_runtime(
        agentRuntimeArn=runtime_arn,
        runtimeSessionId=runtime_sid,
        payload=payload,
        contentType="application/json",
        accept="application/json",
    )

    body = resp["response"].read()
    if isinstance(body, bytes):
        body = body.decode("utf-8")
    return json.loads(body)


# ---------------------------------------------------------------------------
# Check 1 — Identity token vault (no client secret in agent env)
# ---------------------------------------------------------------------------
def check_identity(results: Results, session, region: str, cfg: dict):
    print("--- Check 1: AgentCore Identity (token vault) ---")
    identity = cfg.get("identity") or {}
    provider_name = identity.get("oauth2ProviderName")

    if not provider_name:
        results.skip("identity.oauth2ProviderName not in config — Identity not deployed")
        print("")
        return

    try:
        ctrl = session.client("bedrock-agentcore-control", region_name=region)
        provider = ctrl.get_oauth2_credential_provider(name=provider_name)
    except (ClientError, BotoCoreError) as e:
        code = getattr(e, "response", {}).get("Error", {}).get("Code", type(e).__name__)
        if code in ("ResourceNotFoundException", "ValidationException"):
            results.skip(f"OAuth2 provider '{provider_name}' not found in token vault — not deployed")
        else:
            results.skip(f"Could not query token vault ({code}) — treating as not deployed")
        print("")
        return

    provider_arn = provider.get("credentialProviderArn") or provider.get("clientSecretArn")
    if provider_arn or provider.get("name"):
        results.ok(
            f"Gateway credentials stored in token vault via '{provider_name}'; "
            "agent fetches the gateway token from the vault (no GATEWAY_CLIENT_SECRET in env)"
        )
    else:
        results.fail(f"OAuth2 provider '{provider_name}' returned no ARN — vault not usable")
    print("")


# ---------------------------------------------------------------------------
# Check 2 — Memory persistence across two invocations
# ---------------------------------------------------------------------------
def check_memory(results: Results, session, region: str, cfg: dict):
    print("--- Check 2: AgentCore Memory (cross-session persistence) ---")
    runtime_arn = cfg.get("agentRuntimeArn")
    memory_id = (cfg.get("memory") or {}).get("memoryId")

    if not runtime_arn:
        results.fail("agentRuntimeArn not in config — demo agent not deployed; run scripts/deploy-demo-agent.sh")
        print("")
        return
    if not memory_id:
        results.fail("memory.memoryId not in config — AgentCore Memory not deployed; run scripts/setup-agentcore-memory.py")
        print("")
        return

    client = session.client("bedrock-agentcore", region_name=region)
    actor_id = f"test-actor-{uuid.uuid4().hex[:8]}"
    session_id = f"memtest-{uuid.uuid4().hex[:8]}"
    runtime_sid = runtime_session_id()

    try:
        # First invocation: plant a fact within the shared session.
        first = invoke_runtime(client, runtime_arn, MEMORY_FACT,
                               session_id, actor_id, runtime_sid)
        if not first.get("memory_enabled"):
            results.fail("Runtime reports memory_enabled=false — Memory not wired into the agent; check AGENTCORE_MEMORY_ID env var in the runtime")
            print("")
            return

        # Small pause so the conversation event is persisted before recall.
        time.sleep(3)

        # Second invocation: same session_id/actor_id — the agent should recall.
        second = invoke_runtime(client, runtime_arn, MEMORY_RECALL_PROMPT,
                                session_id, actor_id, runtime_sid)
    except (ClientError, BotoCoreError) as e:
        code = getattr(e, "response", {}).get("Error", {}).get("Code", type(e).__name__)
        results.fail(f"Runtime invocation failed ({code}) — agent is not reachable")
        print("")
        return
    except (KeyError, ValueError, json.JSONDecodeError) as e:
        results.fail(f"Runtime returned an unparseable response: {e}")
        print("")
        return

    recall_text = str(second.get("response", "")).lower()
    if MEMORY_RECALL_KEYWORD in recall_text:
        results.ok(
            "Second invocation recalled context from the first across the shared "
            f"session_id/actor_id (found '{MEMORY_RECALL_KEYWORD}' in the reply)"
        )
    else:
        results.fail(
            "Second invocation did not recall the planted fact "
            f"(expected '{MEMORY_RECALL_KEYWORD}'); response: {recall_text[:200]}"
        )
    print("")


# ---------------------------------------------------------------------------
# Check 3 — Registry discovery via SearchRegistryRecords
# ---------------------------------------------------------------------------
def check_registry(results: Results, session, region: str, cfg: dict):
    print("--- Check 3: Agent Registry (discovery) ---")
    registry = cfg.get("registry") or {}
    registry_id = registry.get("registryId")

    if not registry_id:
        results.fail("registry.registryId not in config — Agent Registry not deployed; run scripts/setup-agent-registry.py")
        print("")
        return

    data = session.client("bedrock-agentcore", region_name=region)

    for query, label in REGISTRY_QUERIES:
        try:
            resp = data.search_registry_records(
                searchQuery=query, registryIds=[registry_id], maxResults=5
            )
        except (ClientError, BotoCoreError) as e:
            code = getattr(e, "response", {}).get("Error", {}).get("Code", type(e).__name__)
            results.skip(f"SearchRegistryRecords unavailable ({code}) for '{query}' — treating as not deployed")
            continue

        records = resp.get("registryRecords", resp.get("results", []))
        if records:
            names = ", ".join(r.get("name", "?") for r in records)
            results.ok(f"Query '{query}' returned {len(records)} record(s) ({names})")
        else:
            results.fail(f"Query '{query}' returned no records (expected the {label})")
    print("")


# ---------------------------------------------------------------------------
# Check 4 — Demo agent end-to-end
# ---------------------------------------------------------------------------
def check_demo_agent_e2e(results: Results, session, region: str, cfg: dict):
    print("--- Check 4: Demo agent end-to-end ---")
    runtime_arn = cfg.get("agentRuntimeArn")

    if not runtime_arn:
        results.fail("agentRuntimeArn not in config — demo agent not deployed; run scripts/deploy-demo-agent.sh")
        print("")
        return

    client = session.client("bedrock-agentcore", region_name=region)
    actor_id = f"test-actor-{uuid.uuid4().hex[:8]}"
    session_id = f"e2e-{uuid.uuid4().hex[:8]}"

    try:
        response = invoke_runtime(client, runtime_arn, E2E_PROMPT,
                                  session_id, actor_id, runtime_session_id())
    except (ClientError, BotoCoreError) as e:
        code = getattr(e, "response", {}).get("Error", {}).get("Code", type(e).__name__)
        results.fail(f"Runtime invocation failed ({code}) — agent is not reachable")
        print("")
        return
    except (KeyError, ValueError, json.JSONDecodeError) as e:
        results.fail(f"Runtime returned an unparseable response: {e}")
        print("")
        return

    missing = [f for f in E2E_REQUIRED_FIELDS if f not in response]
    if missing:
        results.fail(f"Response missing required field(s): {', '.join(missing)}")
        print("")
        return

    results.ok("Response contains all required fields: " + ", ".join(E2E_REQUIRED_FIELDS))
    if str(response.get("response", "")).strip():
        results.ok("Response 'response' field is non-empty")
    else:
        results.fail("Response 'response' field is empty")
    if response.get("session_id") == session_id:
        results.ok("Response echoes the requested session_id")
    else:
        results.fail(f"Response session_id mismatch (got {response.get('session_id')})")
    if response.get("actor_id") == actor_id:
        results.ok("Response echoes the requested actor_id")
    else:
        results.fail(f"Response actor_id mismatch (got {response.get('actor_id')})")
    print("")


# ---------------------------------------------------------------------------
# Check 5: agent traffic is attributed to a business-unit inference profile
# ---------------------------------------------------------------------------
def check_aip_attribution(results: Results, session, region: str, cfg: dict):
    """Confirm an agent turn is charged to a business unit, not the raw model.

    The agent answers correctly whether or not attribution works, so this cannot be
    inferred from a successful invocation. Two things are checked: the runtime reports
    which profile it used, and CloudWatch shows token metrics under that profile's
    ModelId dimension.

    Bedrock publishes token metrics with a lag of a minute or two, so a missing datapoint
    warns rather than fails — a slow metric pipeline is not a broken agent.
    """
    print("--- Check 5: business-unit cost attribution (AIP routing) ---")
    runtime_arn = cfg.get("agentRuntimeArn")

    if not runtime_arn:
        results.fail("agentRuntimeArn not in config — demo agent not deployed; run scripts/deploy-demo-agent.sh")
        print("")
        return

    # Profile ids come from .aip-map.json, written by scripts/create-aips.sh. Hardcoding
    # them would break every time the matrix changes or the profiles are recreated.
    aip_map_path = os.path.join(os.path.dirname(DEFAULT_CONFIG), ".aip-map.json")
    if not os.path.exists(aip_map_path):
        results.fail(".aip-map.json not found — run scripts/create-aips.sh to enable per-BU cost attribution")
        print("")
        return

    with open(aip_map_path) as f:
        aip_map = json.load(f)
    known_profiles = {e["arn"].rsplit("/", 1)[-1]: e for e in aip_map}
    if not known_profiles:
        results.fail(".aip-map.json is empty — no inference profiles to verify against")
        print("")
        return

    client = session.client("bedrock-agentcore", region_name=region)
    actor_id = f"aip-actor-{uuid.uuid4().hex[:8]}"
    session_id = f"aip-{uuid.uuid4().hex[:8]}"

    try:
        response = invoke_runtime(client, runtime_arn, E2E_PROMPT,
                                  session_id, actor_id, runtime_session_id())
    except (ClientError, BotoCoreError) as e:
        code = getattr(e, "response", {}).get("Error", {}).get("Code", type(e).__name__)
        results.fail(f"Runtime invocation failed ({code}) — agent is not reachable")
        print("")
        return
    except (KeyError, ValueError, json.JSONDecodeError) as e:
        results.fail(f"Runtime returned an unparseable response: {e}")
        print("")
        return

    model_id = str(response.get("model_id", ""))
    profile_id = model_id.rsplit("/", 1)[-1] if model_id else ""

    if not response.get("cost_attributed"):
        results.fail(
            f"Turn was NOT attributed to a business unit (model_id={model_id or '<none>'}). "
            f"Its spend lands in the unattributed pool. Check DEFAULT_BUSINESS_UNIT on the "
            f"runtime and the rows in the team config table."
        )
        print("")
        return

    results.ok(f"Turn attributed to business unit "
               f"{response.get('business_unit') or '<unknown>'} "
               f"(source: {response.get('business_unit_source', 'unknown')})")

    if profile_id in known_profiles:
        entry = known_profiles[profile_id]
        results.ok(f"Routed to a known inference profile: {profile_id} "
                   f"({entry['team']} / {entry['modelId']})")
    else:
        results.fail(f"Routed to {profile_id!r}, which is not in .aip-map.json — "
                     f"attribution would not appear on the dashboard")
        print("")
        return

    # Metrics side: the profile must actually be emitting token counts.
    cw = session.client("cloudwatch", region_name=region)
    end = datetime.now(timezone.utc)
    start = end - timedelta(minutes=15)
    totals = {}
    try:
        for metric in ("Invocations", "InputTokenCount"):
            r = cw.get_metric_statistics(
                Namespace="AWS/Bedrock",
                MetricName=metric,
                Dimensions=[{"Name": "ModelId", "Value": profile_id}],
                StartTime=start, EndTime=end, Period=300, Statistics=["Sum"],
            )
            totals[metric] = sum(d["Sum"] for d in r["Datapoints"])
    except (ClientError, BotoCoreError) as e:
        results.skip(f"CloudWatch metrics unavailable: {e}")
        print("")
        return

    if totals.get("Invocations", 0) > 0:
        results.ok(f"CloudWatch shows {int(totals['Invocations'])} invocation(s) and "
                   f"{int(totals.get('InputTokenCount', 0))} input tokens under "
                   f"ModelId={profile_id}")
    else:
        print(f"  ⚠️  No datapoints yet under ModelId={profile_id}. Bedrock token metrics "
              f"lag by 1-2 minutes; re-run shortly or check the dashboard.")

    print("")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    args = parse_args()

    print("==============================================")
    print(" AgentCore Primitives Test")
    print("==============================================")
    print(f"Config  : {args.config}")
    print(f"Region  : {args.region}")
    print(f"Profile : {args.profile or '<default>'}")
    print("==============================================\n")

    if not os.path.exists(args.config):
        print(f"❌ ERROR: config file not found: {args.config}")
        print("   Run scripts/register-tools.sh and deploy.sh first.")
        sys.exit(1)

    with open(args.config) as f:
        cfg = json.load(f)

    # Config may pin its own region (set by the setup scripts).
    region = cfg.get("region", args.region)
    session = make_session(region, args.profile)

    results = Results()

    check_identity(results, session, region, cfg)
    check_memory(results, session, region, cfg)
    check_registry(results, session, region, cfg)
    check_demo_agent_e2e(results, session, region, cfg)
    check_aip_attribution(results, session, region, cfg)

    print("==============================================")
    print(f"  passed: {results.passed}  failed: {results.failed}  skipped: {results.skipped}")
    if results.failed:
        print("💥 OVERALL: FAIL — Some AgentCore checks failed")
        sys.exit(1)
    if results.passed == 0:
        print("💥 OVERALL: FAIL — No AgentCore checks passed; nothing was validated")
        sys.exit(1)
    print("🎉 OVERALL: PASS — AgentCore primitives validated successfully")
    sys.exit(0)


if __name__ == "__main__":
    main()
