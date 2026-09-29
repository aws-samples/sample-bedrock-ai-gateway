#!/usr/bin/env python3
"""Build and deploy the CloudWatch dashboard, generating the per-business-unit widgets.

The business-unit widgets cannot be static JSON any more. An Application Inference
Profile wraps one model, so a BU using several models has several profiles, and the
set of profile ids is only known after scripts/create-aips.sh has reconciled the
matrix in config/bu-models.json. This script generates those widgets from
.aip-map.json and splices them into dashboards/cloudwatch-dashboard.json.

Generated widgets:
  - Token Usage by Business Unit   : per-BU input/output, summed across the BU's models
  - Estimated Cost by Business Unit: per-BU cost, priced per model then summed
  - Token Usage by Model           : same data cut by model instead of by BU

Cost is metric math over token counts because CloudWatch has no pricing data. Rates
come from config/bu-models.json.

Usage:
  .venv/bin/python scripts/update-dashboard.py [--region us-east-1] [--dry-run]
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

import boto3

ROOT = Path(__file__).resolve().parent.parent
MATRIX_FILE = ROOT / "config" / "bu-models.json"
AIP_MAP_FILE = ROOT / ".aip-map.json"
TEMPLATE_FILE = ROOT / "dashboards" / "cloudwatch-dashboard.json"
AGENTCORE_CONFIG = ROOT / ".agentcore-config.json"

NAMESPACE = "AWS/Bedrock"
FALLBACK_MODEL = "us.anthropic.claude-sonnet-4-6"

# Titles of the widgets this script owns. Any widget with one of these titles is
# replaced by a generated version, so the template keeps only the static widgets.
# Includes superseded titles so a dashboard deployed by an earlier revision is replaced
# rather than ending up with both the old and the new widget.
GENERATED_TITLES = {
    "Token Usage by Business Unit",
    "Token Usage by Model",
    "Estimated Cost by Business Unit (USD, selected time range)",
    "Estimated Cost by Business Unit ($)",
    # Summary widgets — also regenerated so they reflect current AIP IDs.
    "Invocations",
    "Latency p50 / p95",
    "Token Usage Over Time (All)",
    "Bedrock Latency Over Time (p50 / p95)",
}


def short(model_id: str) -> str:
    """Human-readable model label: us.anthropic.claude-haiku-4-5-... -> claude-haiku-4-5."""
    name = model_id.split(".")[-1]
    for suffix in ("-v1:0", "-v1", ":0"):
        if name.endswith(suffix):
            name = name[: -len(suffix)]
    # Drop a trailing date stamp such as claude-haiku-4-5-20251001.
    parts = name.split("-")
    if parts and len(parts[-1]) == 8 and parts[-1].isdigit():
        parts = parts[:-1]
    return "-".join(parts)


def metric(name: str, profile_id: str, mid: str, label: str = "", visible: bool = True):
    opts = {"id": mid, "stat": "Sum", "label": label}
    if not visible:
        opts["visible"] = False
    return [NAMESPACE, name, "ModelId", profile_id, opts]


def invocations_summary(entries: list, x: int, y: int) -> dict:
    """Single-value total invocations across all AIP profiles + direct model."""
    metrics = []
    for e in entries:
        metrics.append([NAMESPACE, "Invocations", "ModelId", e["profileId"],
                        {"stat": "Sum", "label": f"{e['team']} / {short(e['modelId'])}"}])
    metrics.append([NAMESPACE, "Invocations", "ModelId", FALLBACK_MODEL,
                    {"stat": "Sum", "label": "General (unattributed)"}])
    return {
        "type": "metric", "x": x, "y": y, "width": 8, "height": 3,
        "properties": {
            "title": "Invocations",
            "view": "singleValue", "region": "${AWS::Region}",
            "setPeriodToTimeRange": True,
            "metrics": metrics, "stat": "Sum",
        },
    }


def latency_summary(entries: list, x: int, y: int) -> dict:
    """Single-value p50/p95 latency across all AIP profiles."""
    metrics = []
    for e in entries:
        lbl = f"{e['team']} / {short(e['modelId'])}"
        metrics.append([NAMESPACE, "InvocationLatency", "ModelId", e["profileId"],
                        {"stat": "p50", "label": f"{lbl} p50 (ms)"}])
        metrics.append([NAMESPACE, "InvocationLatency", "ModelId", e["profileId"],
                        {"stat": "p95", "label": f"{lbl} p95 (ms)"}])
    return {
        "type": "metric", "x": x, "y": y, "width": 8, "height": 3,
        "properties": {
            "title": "Latency p50 / p95",
            "view": "singleValue", "region": "${AWS::Region}",
            "setPeriodToTimeRange": True,
            "metrics": metrics,
        },
    }


def token_usage_all(entries: list, x: int, y: int) -> dict:
    """Total input/output tokens over time across all AIPs + direct model."""
    metrics = []
    for e in entries:
        lbl = f"{e['team']} / {short(e['modelId'])}"
        metrics.append([NAMESPACE, "InputTokenCount", "ModelId", e["profileId"],
                        {"stat": "Sum", "label": f"{lbl} (in)"}])
        metrics.append([NAMESPACE, "OutputTokenCount", "ModelId", e["profileId"],
                        {"stat": "Sum", "label": f"{lbl} (out)"}])
    metrics.append([NAMESPACE, "InputTokenCount", "ModelId", FALLBACK_MODEL,
                    {"stat": "Sum", "label": "General (in)"}])
    metrics.append([NAMESPACE, "OutputTokenCount", "ModelId", FALLBACK_MODEL,
                    {"stat": "Sum", "label": "General (out)"}])
    return {
        "type": "metric", "x": x, "y": y, "width": 12, "height": 7,
        "properties": {
            "title": "Token Usage Over Time (All)",
            "view": "timeSeries", "stacked": True, "region": "${AWS::Region}",
            "metrics": metrics, "period": 300, "stat": "Sum",
            "yAxis": {"left": {"label": "Tokens", "showUnits": False}},
        },
    }


def latency_over_time(entries: list, x: int, y: int) -> dict:
    """p50/p95 latency over time across all AIP profiles."""
    metrics = []
    for e in entries:
        lbl = f"{e['team']} / {short(e['modelId'])}"
        metrics.append([NAMESPACE, "InvocationLatency", "ModelId", e["profileId"],
                        {"stat": "p50", "label": f"{lbl} p50"}])
        metrics.append([NAMESPACE, "InvocationLatency", "ModelId", e["profileId"],
                        {"stat": "p95", "label": f"{lbl} p95"}])
    return {
        "type": "metric", "x": x, "y": y, "width": 12, "height": 7,
        "properties": {
            "title": "Bedrock Latency Over Time (p50 / p95)",
            "view": "timeSeries", "region": "${AWS::Region}",
            "metrics": metrics, "period": 300,
            "yAxis": {"left": {"label": "Milliseconds", "showUnits": False}},
        },
    }


def token_usage_by_bu(by_team: dict, x: int, y: int) -> dict:
    """Per-BU input/output tokens, summed across each BU's inference profiles."""
    metrics: list = []
    n = 0
    for team, entries in sorted(by_team.items()):
        slug = team.lower().replace("-", "_")
        for direction, mname in (("in", "InputTokenCount"), ("out", "OutputTokenCount")):
            ids = []
            for e in entries:
                n += 1
                mid = f"m{n}"
                ids.append(mid)
                metrics.append(metric(mname, e["profileId"], mid, visible=False))
            expr = "+".join(ids) if len(ids) > 1 else ids[0]
            metrics.append([
                {"expression": expr,
                 "label": f"{team} ({direction})",
                 "id": f"{slug}_{direction}"}
            ])
    return {
        "type": "metric", "x": x, "y": y, "width": 12, "height": 7,
        "properties": {
            "title": "Token Usage by Business Unit",
            "view": "timeSeries", "stacked": True, "region": "${AWS::Region}",
            "metrics": metrics, "period": 300, "stat": "Sum",
            "yAxis": {"left": {"label": "Tokens", "showUnits": False}},
        },
    }


def cost_by_bu(by_team: dict, pricing: dict, x: int, y: int, unpriced: list) -> dict:
    """Per-BU estimated cost. Each model is priced at its own rate, then summed."""
    metrics: list = []
    n = 0
    for team, entries in sorted(by_team.items()):
        slug = team.lower().replace("-", "_")
        terms = []
        for e in entries:
            price = pricing.get(e["modelId"], {})
            p_in = price.get("inputPer1M")
            p_out = price.get("outputPer1M")
            if p_in is None or p_out is None:
                # Excluded from cost but still counted in the token widgets, so the two
                # would disagree. Record it so the caller can surface it rather than
                # letting a business unit's cost quietly read low.
                unpriced.append(f"{team}/{e['modelId']}")
                continue
            n += 1
            in_id, out_id = f"c{n}i", f"c{n}o"
            metrics.append(metric("InputTokenCount", e["profileId"], in_id, visible=False))
            metrics.append(metric("OutputTokenCount", e["profileId"], out_id, visible=False))
            terms.append(f"({in_id}*{p_in}+{out_id}*{p_out})")
        if not terms:
            continue
        metrics.append([
            {"expression": f"({'+'.join(terms)})/1000000",
             "label": team, "id": f"cost_{slug}"}
        ])

    # Unattributed traffic: calls that named no business unit.
    price = pricing.get(FALLBACK_MODEL, {"inputPer1M": 3.0, "outputPer1M": 15.0})
    metrics.append(metric("InputTokenCount", FALLBACK_MODEL, "gen_i", visible=False))
    metrics.append(metric("OutputTokenCount", FALLBACK_MODEL, "gen_o", visible=False))
    metrics.append([
        {"expression": f"(gen_i*{price['inputPer1M']}+gen_o*{price['outputPer1M']})/1000000",
         "label": "General (unattributed)", "id": "cost_general"}
    ])

    # setPeriodToTimeRange makes each datapoint cover the whole selected range, so the
    # number reads as a total for that range. Without it the widget silently plots
    # USD-per-period, and widening the time range rescales every value while the title
    # still says "cost" — which invites reading an hourly rate as a total. The static
    # widgets in the template already set this; these were the outliers.
    return {
        "type": "metric", "x": x, "y": y, "width": 24, "height": 6,
        "properties": {
            "title": "Estimated Cost by Business Unit (USD, selected time range)",
            "view": "timeSeries", "stacked": True, "region": "${AWS::Region}",
            "metrics": metrics, "period": 3600, "stat": "Sum",
            "setPeriodToTimeRange": True,
            "yAxis": {"left": {"label": "USD", "showUnits": False, "min": 0}},
            "legend": {"position": "right"},
        },
    }


def token_usage_by_model(entries: list, x: int, y: int) -> dict:
    """Same tokens, cut by model rather than by business unit."""
    metrics: list = []
    for e in entries:
        label = f"{short(e['modelId'])} / {e['team']}"
        metrics.append([NAMESPACE, "InputTokenCount", "ModelId", e["profileId"],
                        {"stat": "Sum", "label": label}])
    return {
        "type": "metric", "x": x, "y": y, "width": 12, "height": 7,
        "properties": {
            "title": "Token Usage by Model",
            "view": "timeSeries", "stacked": False, "region": "${AWS::Region}",
            "metrics": metrics, "period": 300, "stat": "Sum",
            "yAxis": {"left": {"label": "Input tokens", "showUnits": False}},
        },
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--region", default=os.environ.get("AWS_REGION", "us-east-1"))
    ap.add_argument("--stage", default="poc")
    ap.add_argument("--company-name", default=os.environ.get("COMPANY_NAME", "anycompany"))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    for f in (MATRIX_FILE, AIP_MAP_FILE, TEMPLATE_FILE):
        if not f.exists():
            print(f"ERROR: {f} not found"
                  f"{' — run scripts/create-aips.sh first' if f == AIP_MAP_FILE else ''}")
            return 1

    matrix = json.loads(MATRIX_FILE.read_text())
    aip_map = json.loads(AIP_MAP_FILE.read_text())
    pricing = matrix.get("modelPricing", {})

    entries = [
        {"team": e["team"], "modelId": e["modelId"],
         "profileId": e["arn"].rsplit("/", 1)[-1].strip()}
        for e in aip_map
    ]
    by_team: dict = {}
    for e in entries:
        by_team.setdefault(e["team"], []).append(e)

    print(f"  {len(entries)} inference profiles across {len(by_team)} business units")
    for team, es in sorted(by_team.items()):
        print(f"    {team}: " + ", ".join(f"{short(e['modelId'])}={e['profileId']}" for e in es))

    # Keep the static widgets, drop the ones this script owns.
    dash = json.loads(TEMPLATE_FILE.read_text())
    kept = [w for w in dash["widgets"]
            if w.get("properties", {}).get("title") not in GENERATED_TITLES]
    dropped = len(dash["widgets"]) - len(kept)
    print(f"  kept {len(kept)} static widgets, regenerating {dropped}")

    # Place generated widgets below everything else so static layout is untouched.
    base_y = max((w.get("y", 0) + w.get("height", 6) for w in kept), default=0)
    unpriced: list = []

    # Summary widgets (row y=1): regenerated to reflect current AIP profile IDs.
    # Token/Cost widgets: Token All + Token by BU share row y=11,
    # Token by Model + Cost follow at y=18 and y=25.
    generated = [
        invocations_summary(entries, 0, 1),
        latency_summary(entries, 8, 1),
        token_usage_all(entries, 0, 11),
        token_usage_by_bu(by_team, 12, 11),
        token_usage_by_model(entries, 0, 18),
        latency_over_time(entries, 12, 18),
        cost_by_bu(by_team, pricing, 0, 25, unpriced),
    ]

    # A model missing from modelPricing is silently absent from the cost widget while
    # still appearing in the token widgets, so a business unit's cost reads low with no
    # indication why. Say so, and put it on the dashboard rather than only in this output.
    if unpriced:
        for item in unpriced:
            print(f"  ! no pricing for {item} — excluded from the cost widget",
                  file=sys.stderr)
        generated.append({
            "type": "text", "x": 0, "y": base_y + 13, "width": 24, "height": 2,
            "properties": {
                "markdown": (
                    "⚠️ **Estimated cost is incomplete.** No pricing in "
                    "`config/bu-models.json` for: "
                    + ", ".join(f"`{i}`" for i in sorted(unpriced))
                    + ". Token usage for these is charted above but their cost is **not** "
                      "included below, so the affected business units read low."
                ),
            },
        })

    dash["widgets"] = kept + generated

    body = json.dumps(dash)

    runtime_id = ""
    if AGENTCORE_CONFIG.exists():
        runtime_id = json.loads(AGENTCORE_CONFIG.read_text()).get("agentRuntimeId", "")
    body = body.replace("${AWS::Region}", args.region)
    body = body.replace("${AGENTCORE_RUNTIME_ID}", runtime_id)
    body = body.replace("${STACK_NAME}", f"{args.company_name}-ai-gateway-{args.stage}")

    # Legacy single-profile placeholders are gone now that the widgets are generated.
    # Fail rather than deploy a dashboard that silently queries a literal "${...}".
    if "${" in body:
        leftover = sorted({body[m.start():body.index('}', m.start()) + 1]
                           for m in __import__("re").finditer(r"\$\{", body)})
        print(f"ERROR: unresolved placeholders remain: {leftover}")
        return 1

    name = f"{args.company_name}-ai-gateway-{args.stage}"
    if args.dry_run:
        print(f"  dry run: would put dashboard '{name}' "
              f"({len(dash['widgets'])} widgets, {len(body)} bytes)")
        return 0

    boto3.client("cloudwatch", region_name=args.region).put_dashboard(
        DashboardName=name, DashboardBody=body
    )
    print(f"  deployed dashboard '{name}' with {len(dash['widgets'])} widgets")
    print(f"  https://console.aws.amazon.com/cloudwatch/home?region={args.region}"
          f"#dashboards/dashboard/{name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
