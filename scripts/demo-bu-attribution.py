#!/usr/bin/env python3
"""Live demo: per-business-unit, per-model cost attribution and entitlement.

Story this tells, in order:
  1. Entitlement and attribution are one config table. Each business unit is mapped
     to a set of models, and each (BU, model) pair has its own Application Inference
     Profile, because a profile wraps exactly one model.
  2. The same agent invoked by two business units routes to two different profiles,
     decided server side from config rather than anything the agent hard codes.
  3. A business unit asking for a model it is not entitled to is refused, so the
     table controls spend as well as reporting it.
  4. Bedrock emits token metrics per profile, so CloudWatch shows a live per-BU and
     per-model token and cost split within a couple of minutes of each call.

Usage:
  .venv/bin/python scripts/demo-bu-attribution.py            # full demo
  .venv/bin/python scripts/demo-bu-attribution.py --metrics  # metrics table only
"""
from __future__ import annotations

import json
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import boto3

ROOT = Path(__file__).resolve().parent.parent
MATRIX_FILE = ROOT / "config" / "bu-models.json"
AGENTCORE_CONFIG = ROOT / ".agentcore-config.json"

TABLE = "ai-gateway-team-config"
FALLBACK_MODEL = "us.anthropic.claude-sonnet-4-6"
STAGE = "poc"

# Everything account-specific is discovered at runtime so this script works in any
# account the project is deployed to.
_cfg = json.loads(AGENTCORE_CONFIG.read_text()) if AGENTCORE_CONFIG.exists() else {}
REGION = _cfg.get("region") or "us-east-1"
RUNTIME_ARN = _cfg.get("agentRuntimeArn")
ACCOUNT_ID = RUNTIME_ARN.split(":")[4] if RUNTIME_ARN else "unknown"

# Derive dashboard name from STACK_NAME env var (set by deploy.sh) or fall back
# to the default anycompany naming convention.
import os as _os
_stack = _os.environ.get("STACK_NAME", f"anycompany-ai-gateway-{STAGE}")
DASHBOARD_URL = (
    f"https://console.aws.amazon.com/cloudwatch/home?region={REGION}"
    f"#dashboards/dashboard/{_stack}"
)

BAR = "=" * 78


def rule(title: str) -> None:
    print(f"\n{BAR}\n  {title}\n{BAR}")


def short(model_id: str) -> str:
    name = model_id.split(".")[-1]
    for suffix in ("-v1:0", "-v1", ":0"):
        if name.endswith(suffix):
            name = name[: -len(suffix)]
    parts = name.split("-")
    if parts and len(parts[-1]) == 8 and parts[-1].isdigit():
        parts = parts[:-1]
    return "-".join(parts)


def load_pricing() -> dict:
    if MATRIX_FILE.exists():
        return json.loads(MATRIX_FILE.read_text()).get("modelPricing", {})
    return {}


def load_team_config() -> dict:
    """Read the live routing table: team -> {models: {modelId: profileId}, ...}."""
    ddb = boto3.client("dynamodb", region_name=REGION)
    rows = {}
    for it in ddb.scan(TableName=TABLE)["Items"]:
        models = {
            k: v["S"].strip().rsplit("/", 1)[-1]
            for k, v in it.get("models", {}).get("M", {}).items()
        }
        if not models:
            # Legacy single-model row.
            arn = it.get("aip_arn", {}).get("S", "").strip()
            if arn:
                models = {it.get("default_model", {}).get("S", FALLBACK_MODEL):
                          arn.rsplit("/", 1)[-1]}
        rows[it["team"]["S"]] = {
            "models": models,
            "default_model": it.get("default_model", {}).get("S", ""),
            "cost_center": it.get("cost_center", {}).get("S", "-"),
            "budget": it.get("budget_limit", {}).get("N", "-"),
            "active": it.get("active", {}).get("BOOL", False),
        }
    return rows


def show_config(cfg: dict, pricing: dict) -> None:
    rule("1. Entitlement and attribution are the same config")
    print(f"  {'BUSINESS UNIT':<16}{'MODEL':<22}{'PROFILE':<15}{'$/1M IN':<10}"
          f"{'$/1M OUT':<10}DEFAULT")
    for team, r in sorted(cfg.items()):
        for model, profile in sorted(r["models"].items()):
            p = pricing.get(model, {})
            is_def = "yes" if model == r["default_model"] else ""
            print(f"  {team:<16}{short(model):<22}{profile:<15}"
                  f"{p.get('inputPer1M', '?'):<10}{p.get('outputPer1M', '?'):<10}{is_def}")
    print(f"\n  Source: DynamoDB {TABLE}, generated from config/bu-models.json")
    print("  A profile wraps one model, so each (BU, model) pair gets its own profile.")
    print("  The model list is also the allow-list: unlisted models are refused.")


def token_metrics(model_id: str, start, end) -> dict:
    cw = boto3.client("cloudwatch", region_name=REGION)
    out = {}
    for metric in ("Invocations", "InputTokenCount", "OutputTokenCount"):
        r = cw.get_metric_statistics(
            Namespace="AWS/Bedrock",
            MetricName=metric,
            Dimensions=[{"Name": "ModelId", "Value": model_id}],
            StartTime=start, EndTime=end, Period=300, Statistics=["Sum"],
        )
        out[metric] = int(sum(d["Sum"] for d in r["Datapoints"]))
    return out


def cost_of(m: dict, model_id: str, pricing: dict) -> float:
    p = pricing.get(model_id, {"inputPer1M": 3.0, "outputPer1M": 15.0})
    return (m["InputTokenCount"] * p["inputPer1M"]
            + m["OutputTokenCount"] * p["outputPer1M"]) / 1_000_000


def snapshot(cfg: dict, hours: int = 2) -> dict:
    """Per (team, model) metrics, plus the unattributed General bucket."""
    end = datetime.now(timezone.utc)
    start = end - timedelta(hours=hours)
    snap = {}
    for team, r in cfg.items():
        for model, profile in r["models"].items():
            snap[(team, model)] = token_metrics(profile, start, end)
    snap[("General", FALLBACK_MODEL)] = token_metrics(FALLBACK_MODEL, start, end)
    return snap


def invoke(business_unit: str | None, prompt: str, model: str | None = None) -> dict:
    payload = {
        "prompt": prompt,
        "actor_id": f"demo-{(business_unit or 'unassigned').lower()}",
        "session_id": f"demo-{uuid.uuid4().hex[:8]}",
    }
    if business_unit:
        payload["business_unit"] = business_unit
    if model:
        payload["model"] = model

    client = boto3.client("bedrock-agentcore", region_name=REGION)
    resp = client.invoke_agent_runtime(
        agentRuntimeArn=RUNTIME_ARN,
        runtimeSessionId=f"{uuid.uuid4()}{uuid.uuid4()}"[:40],
        payload=json.dumps(payload).encode(),
    )
    return json.loads(resp["response"].read().decode())


def report(body: dict, took: float) -> None:
    if "error" in body:
        print(f"      refused           : {body['error'][:110]}")
        return
    print(f"      routed to profile : {(body.get('model_id') or '').rsplit('/', 1)[-1]}")
    print(f"      cost attributed   : {body.get('cost_attributed')}")
    print(f"      latency           : {took:.1f}s")
    answer = " ".join(str(body.get("response", "")).split())
    print(f"      answer            : {answer[:130]}")


def run_turns(cfg: dict) -> None:
    rule("2. Same agent, two business units, two inference profiles")
    for team in sorted(cfg):
        print(f"\n  --> invoking as {team} (default model)")
        t0 = time.time()
        try:
            body = invoke(team, "Search the knowledge base for tire pressure monitoring "
                                "and summarise in one sentence.")
            report(body, time.time() - t0)
        except Exception as e:  # noqa: BLE001 - demo must keep going
            print(f"      INVOKE FAILED: {type(e).__name__}: {e}")

    rule("3. A second model for the same business unit, attributed separately")
    for team, r in sorted(cfg.items()):
        extra = [m for m in sorted(r["models"]) if m != r["default_model"]]
        if not extra:
            continue
        model = extra[0]
        print(f"\n  --> invoking as {team} asking for {short(model)}")
        t0 = time.time()
        try:
            report(invoke(team, "Reply in one short sentence: what is TPMS?", model),
                   time.time() - t0)
        except Exception as e:  # noqa: BLE001
            print(f"      INVOKE FAILED: {type(e).__name__}: {e}")

    rule("4. A model the business unit is not entitled to is refused")
    teams = sorted(cfg)
    for team in teams:
        others = {m for t in teams if t != team for m in cfg[t]["models"]}
        forbidden = sorted(others - set(cfg[team]["models"]))
        if not forbidden:
            continue
        model = forbidden[0]
        print(f"\n  --> {team} asking for {short(model)} (entitled to another BU only)")
        try:
            body = invoke(team, "Reply with: ok", model)
            if "error" in body:
                print(f"      REFUSED: {body['error'][:120]}")
            else:
                print(f"      UNEXPECTEDLY ALLOWED -> {body.get('model_id')}")
        except Exception as e:  # noqa: BLE001
            print(f"      INVOKE FAILED: {type(e).__name__}: {e}")
    print("\n  No model call is made, so no spend is incurred on a refused request.")


def show_metrics(cfg: dict, pricing: dict, before: dict | None = None,
                 wait_s: int = 0) -> None:
    rule("5. Live token and cost split by business unit and model (CloudWatch)")

    if wait_s and before is not None:
        print(f"  Bedrock publishes token metrics with a short lag. Polling up to {wait_s}s")
        deadline = time.time() + wait_s
        while time.time() < deadline:
            after = snapshot(cfg)
            if any(after[k]["InputTokenCount"] > before.get(k, {}).get("InputTokenCount", 0)
                   for k in after):
                print("  New datapoints landed.")
                break
            time.sleep(10)  # intentional: poll interval waiting for CloudWatch metrics  # nosemgrep
            print("  ...waiting")
        else:
            print("  Lag still in flight; showing cumulative totals.")

    after = snapshot(cfg)

    print(f"\n  {'BUSINESS UNIT':<16}{'MODEL':<22}{'CALLS':<7}{'IN':<9}{'OUT':<8}"
          f"{'EST COST':<12}{'THIS RUN':<10}")

    totals: dict = {}
    grand = 0.0
    attributed = 0.0
    for (team, model), m in sorted(after.items()):
        c = cost_of(m, model, pricing)
        grand += c
        if team != "General":
            attributed += c
            totals[team] = totals.get(team, 0.0) + c
        delta = ""
        if before and (team, model) in before:
            d = ((m["InputTokenCount"] - before[(team, model)]["InputTokenCount"])
                 + (m["OutputTokenCount"] - before[(team, model)]["OutputTokenCount"]))
            if d:
                delta = f"+{d} tok"
        label = team if team != "General" else "General"
        print(f"  {label:<16}{short(model):<22}{m['Invocations']:<7}"
              f"{m['InputTokenCount']:<9}{m['OutputTokenCount']:<8}${c:<11.6f}{delta:<10}")

    print(f"\n  {'PER BUSINESS UNIT':<32}EST COST")
    for team, c in sorted(totals.items()):
        print(f"  {team:<32}${c:.6f}")

    pct = (attributed / grand * 100) if grand else 0.0
    print(f"\n  Total spend (2h window) : ${grand:.6f}")
    print(f"  Attributed to a BU      : ${attributed:.6f}  ({pct:.0f}%)")
    print("\n  Cost is metric math over token counts at the per-model rates in")
    print("  config/bu-models.json. Cost Explorer remains the billing source of truth.")
    print(f"  Dashboard: {DASHBOARD_URL}")


def main() -> None:
    metrics_only = "--metrics" in sys.argv

    if not metrics_only and not RUNTIME_ARN:
        print("No agentRuntimeArn in .agentcore-config.json — the demo agent is not "
              "deployed.\nRun scripts/deploy-demo-agent.sh, or use --metrics to show "
              "the cost table only.")
        sys.exit(1)

    cfg = load_team_config()
    pricing = load_pricing()
    if not cfg:
        print(f"No rows in {TABLE}. Run scripts/create-aips.sh then "
              f"scripts/create-team-config-table.sh.")
        sys.exit(1)

    print(BAR)
    print("  AI GATEWAY - BUSINESS UNIT COST ATTRIBUTION AND ENTITLEMENT")
    print(f"  account {ACCOUNT_ID} | {REGION} | "
          f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(BAR)

    show_config(cfg, pricing)

    if metrics_only:
        show_metrics(cfg, pricing)
        return

    before = snapshot(cfg)
    run_turns(cfg)
    show_metrics(cfg, pricing, before=before, wait_s=90)

    rule("What this means")
    print("  Every model call is attributed to a business unit and a model")
    print("  automatically, from configuration rather than from application code.")
    print("  The same table decides what a business unit is allowed to run, so")
    print("  entitlement and chargeback never drift apart. Adding a business unit or")
    print("  a model is an edit to config/bu-models.json and a redeploy of config,")
    print("  with no change to the agent or the gateway.")


if __name__ == "__main__":
    main()
