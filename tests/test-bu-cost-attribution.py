#!/usr/bin/env python3
"""
test-bu-cost-attribution.py — Validate per-business-unit model routing and entitlement.

Why this test exists: a mistake in this logic does not surface as an error. The request
still succeeds and still returns an answer — it is just billed to the wrong cost center,
or a business unit quietly gains access to a model it was never entitled to. That makes
it exactly the kind of logic that regresses unnoticed, so the rules are pinned here.

Two independent layers are checked:

  1. Resolver unit checks (offline, no AWS calls)
     Drives custom-lambdas/demo-agent/agent.py resolve_model_id() against a stubbed
     DynamoDB covering every branch: default model, entitled explicit model,
     non-entitled model, inactive business unit, unknown business unit, legacy rows
     with no models map, lookup failure, whitespace, and cache keying.

  2. Live config checks (require AWS)
     Assert the deployed ai-gateway-team-config table actually reflects
     config/bu-models.json, that every referenced inference profile exists, and that
     no two (business unit, model) pairs share a profile — sharing one would silently
     merge two cost centers.

Usage:
    # Offline only — safe anywhere, no credentials needed:
    python tests/test-bu-cost-attribution.py

    # Include the live checks against the deployed account:
    python tests/test-bu-cost-attribution.py --live
    python tests/test-bu-cost-attribution.py --live --region us-east-1
"""
import argparse
import json
import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AGENT_DIR = os.path.join(REPO_ROOT, "custom-lambdas", "demo-agent")
MATRIX_FILE = os.path.join(REPO_ROOT, "config", "bu-models.json")
TEAM_CONFIG_TABLE = "ai-gateway-team-config"

SONNET = "us.anthropic.claude-sonnet-4-6"
HAIKU = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
NOVA = "us.amazon.nova-lite-v1:0"

ARN_A = "arn:aws:bedrock:us-east-1:111122223333:application-inference-profile/aaaaaaaaaaaa"
ARN_B = "arn:aws:bedrock:us-east-1:111122223333:application-inference-profile/bbbbbbbbbbbb"
ARN_LEGACY = "arn:aws:bedrock:us-east-1:111122223333:application-inference-profile/cccccccccccc"


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


def parse_args():
    p = argparse.ArgumentParser(description="Business-unit cost attribution validation")
    p.add_argument("--live", action="store_true",
                   help="Also check the deployed table and inference profiles")
    p.add_argument("--region", default=os.environ.get("AWS_REGION", "us-east-1"))
    p.add_argument("--profile", default=os.environ.get("AWS_PROFILE"))
    return p.parse_args()


# ---------------------------------------------------------------------------
# Stubbed DynamoDB: one row per scenario the resolver has to handle
# ---------------------------------------------------------------------------
STUB_ROWS = {
    # Two entitled models, sonnet is the default.
    "Architecture": {
        "team": {"S": "Architecture"},
        "active": {"BOOL": True},
        "default_model": {"S": SONNET},
        "models": {"M": {SONNET: {"S": ARN_A}, HAIKU: {"S": ARN_B}}},
        "aip_arn": {"S": ARN_A},
    },
    # Provisioned but switched off.
    "Retired": {
        "team": {"S": "Retired"},
        "active": {"BOOL": False},
        "default_model": {"S": SONNET},
        "models": {"M": {SONNET: {"S": ARN_A}}},
        "aip_arn": {"S": ARN_A},
    },
    # Row written before the models map existed: single profile, no allow-list.
    "LegacyBU": {
        "team": {"S": "LegacyBU"},
        "active": {"BOOL": True},
        "aip_arn": {"S": ARN_LEGACY},
    },
    # Active but misconfigured: no profile of any kind.
    "Empty": {
        "team": {"S": "Empty"},
        "active": {"BOOL": True},
    },
    # Stored ARN carries stray whitespace, as a hand-edited row would.
    "Padded": {
        "team": {"S": "Padded"},
        "active": {"BOOL": True},
        "default_model": {"S": SONNET},
        "models": {"M": {SONNET: {"S": f"  {ARN_A} "}}},
        "aip_arn": {"S": f"  {ARN_A} "},
    },
    # Present in config but never activated — treated as not provisioned.
    "NoActiveFlag": {
        "team": {"S": "NoActiveFlag"},
        "default_model": {"S": SONNET},
        "models": {"M": {SONNET: {"S": ARN_A}}},
    },
}


class StubDynamoDB:
    def __init__(self):
        self.calls = []

    def get_item(self, TableName, Key):
        team = Key["team"]["S"]
        self.calls.append(team)
        if team == "Exploding":
            raise RuntimeError("simulated DynamoDB outage")
        item = STUB_ROWS.get(team)
        return {"Item": item} if item else {}


def load_agent_module(r: Results):
    """Import the agent module, or skip the offline suite if deps are unavailable."""
    sys.path.insert(0, AGENT_DIR)
    try:
        import agent  # noqa: PLC0415 — deliberately late, needs sys.path set first
        return agent
    except ImportError as e:
        r.skip(f"cannot import agent.py ({e}). Install deps: "
               f"pip install -r custom-lambdas/demo-agent/requirements.txt")
        return None


# ---------------------------------------------------------------------------
# Check 1: resolver behaviour, offline
# ---------------------------------------------------------------------------
def check_resolver(r: Results):
    print("--- Check 1: resolve_model_id() branches (offline) ---")
    agent = load_agent_module(r)
    if agent is None:
        print("")
        return

    stub = StubDynamoDB()
    agent._get_dynamodb = lambda: stub
    agent._aip_cache.clear()

    def expect(label, want, bu, model=None):
        try:
            got = agent.resolve_model_id(bu, model)
        except Exception as e:  # noqa: BLE001
            r.fail(f"{label}: raised {type(e).__name__}: {e}")
            return
        if got == want:
            r.ok(f"{label} -> {got.rsplit('/', 1)[-1]}")
        else:
            r.fail(f"{label}: got {got!r}, want {want!r}")

    def expect_raises(label, exc, bu, model=None):
        try:
            got = agent.resolve_model_id(bu, model)
        except exc:
            r.ok(f"{label} -> {exc.__name__}")
        except Exception as e:  # noqa: BLE001
            r.fail(f"{label}: raised {type(e).__name__}, want {exc.__name__}")
        else:
            r.fail(f"{label}: returned {got!r}, want {exc.__name__}")

    # No business unit means no attribution: fall back to the raw model.
    expect("no business unit falls back to raw model", agent.MODEL_ID, None)
    expect("empty business unit falls back to raw model", agent.MODEL_ID, "")

    # Entitled models resolve to their own profile, one per model.
    expect("default model when none requested", ARN_A, "Architecture")
    expect("explicit default model", ARN_A, "Architecture", SONNET)
    expect("explicit second entitled model", ARN_B, "Architecture", HAIKU)

    # The models map is an allow-list.
    expect_raises("non-entitled model is refused",
                  agent.ModelNotEntitledError, "Architecture", NOVA)

    # Deactivating a business unit denies it outright.
    expect_raises("inactive business unit is denied",
                  agent.InactiveBusinessUnitError, "Retired")
    expect_raises("missing active flag is denied",
                  agent.InactiveBusinessUnitError, "NoActiveFlag")

    # Config problems degrade attribution, they do not break the request.
    expect("unknown business unit falls back", agent.MODEL_ID, "NeverHeardOfIt")
    expect("lookup failure falls back", agent.MODEL_ID, "Exploding")
    expect("row with no profile falls back", agent.MODEL_ID, "Empty")

    # Legacy rows predating the models map keep working, without entitlement checks.
    expect("legacy row uses aip_arn", ARN_LEGACY, "LegacyBU")
    expect("legacy row ignores requested model", ARN_LEGACY, "LegacyBU", NOVA)

    # Bedrock reports a whitespace-padded model id as an invalid identifier, which is
    # a misleading error, so the resolver trims on read.
    expect("stored ARN is trimmed", ARN_A, "Padded")
    expect("requested model is trimmed", ARN_B, " Architecture ", f" {HAIKU} ")

    # The cache must key on (business unit, model). Keying on the business unit alone
    # would return one model's profile for every model that unit uses.
    agent._aip_cache.clear()
    stub.calls.clear()
    first = agent.resolve_model_id("Architecture", SONNET)
    second = agent.resolve_model_id("Architecture", HAIKU)
    if first != second:
        r.ok("cache distinguishes models within one business unit")
    else:
        r.fail(f"cache collision: both models resolved to {first}")

    before = len(stub.calls)
    agent.resolve_model_id("Architecture", SONNET)
    if len(stub.calls) == before:
        r.ok("repeat resolution is served from cache")
    else:
        r.fail("cache miss on a repeated resolution")

    # Fallbacks must not be cached, or a transient outage would pin a business unit
    # to the unattributed pool for the life of the container.
    if not any(k[0] == "Exploding" for k in agent._aip_cache):
        r.ok("fallbacks are not cached")
    else:
        r.fail("a fallback was cached and would persist after recovery")

    print("")


# ---------------------------------------------------------------------------
# Check 1b: the fallback is narrow, and reports honestly
# ---------------------------------------------------------------------------
def check_fallback_safety(r: Results):
    """The AIP fallback must not retry arbitrary failures, and must not claim success.

    Two regressions this pins:

    1. The retry originally caught every exception on an attributed turn. Retrying
       re-runs the whole prompt, and this agent has a create_ticket tool, so a throttle
       or a mid-stream failure after a ticket was created would create a second ticket
       and spend a second turn's tokens.
    2. cost_attributed was computed from the *resolved* profile before the turn ran, so a
       turn that fell back to the raw model still reported cost_attributed=True — hiding
       exactly the condition the attribution checks exist to detect.
    """
    print("--- Check 1b: fallback is narrow and reports honestly (offline) ---")
    agent = load_agent_module(r)
    if agent is None:
        print("")
        return

    class FakeClientError(Exception):
        """Shaped like botocore's ClientError, which is what Strands surfaces."""

        def __init__(self, code, message):
            super().__init__(message)
            self.response = {"Error": {"Code": code, "Message": message}}

    invalid_model = FakeClientError(
        "ValidationException",
        "An error occurred (ValidationException) when calling the ConverseStream "
        "operation: The provided model identifier is invalid.",
    )
    throttle = FakeClientError(
        "ThrottlingException", "Too many requests, please wait before trying again.")
    validation_other = FakeClientError(
        "ValidationException", "messages.0.content: at least one item is required")

    # Strands does not surface the botocore error directly. event_loop_cycle re-raises it
    # as EventLoopException, which keeps the original on .original_exception and passes
    # only str(original) to Exception.__init__ — so the outermost exception has no
    # .response at all. The unwrapped cases below are not representative of the runtime on
    # their own; an earlier revision of this check used only those and passed while the
    # fallback was dead in production.
    class FakeEventLoopException(Exception):
        def __init__(self, original):
            super().__init__(str(original))
            self.original_exception = original

    class FakeHttpError(Exception):
        """Has a .response that is NOT a dict, as httpx does — must not raise."""

        def __init__(self, message):
            super().__init__(message)
            self.response = object()

    access_denied = FakeClientError(
        "AccessDeniedException",
        "User is not authorized to perform: bedrock:InvokeModel on the provided resource")

    cases = [
        ("invalid model identifier is retryable", invalid_model, True),
        ("WRAPPED invalid model identifier is retryable (the real runtime shape)",
         FakeEventLoopException(invalid_model), True),
        ("doubly wrapped is still retryable",
         FakeEventLoopException(FakeEventLoopException(invalid_model)), True),
        ("throttling is NOT retryable", throttle, False),
        ("wrapped throttling is NOT retryable",
         FakeEventLoopException(throttle), False),
        ("unrelated ValidationException is NOT retryable", validation_other, False),
        ("access denied is NOT retryable", access_denied, False),
        ("plain exception is NOT retryable", RuntimeError("connection reset"), False),
        ("tool failure is NOT retryable", ValueError("tool returned 500"), False),
        ("non-dict .response does not raise", FakeHttpError("mcp gateway 502"), False),
    ]
    for label, exc, want in cases:
        got = agent._is_invalid_model_error(exc)
        if got == want:
            r.ok(f"{label}")
        else:
            r.fail(f"{label}: got {got}, want {want}")

    # run_prompt must return the model actually used, so the caller can report honestly.
    import inspect
    src = inspect.getsource(agent.run_prompt)
    if "return _run(model_id), model_id" in src and "return _run(MODEL_ID), MODEL_ID" in src:
        r.ok("run_prompt returns the model actually used on both paths")
    else:
        r.fail("run_prompt does not return the model actually used — cost_attributed "
               "would be computed from the resolved profile and could overstate "
               "attribution after a fallback")

    entry_src = inspect.getsource(agent.invoke) if hasattr(agent, "invoke") else ""
    if entry_src:
        if "used_model_id != MODEL_ID" in entry_src:
            r.ok("cost_attributed is derived from the model actually used")
        else:
            r.fail("cost_attributed is not derived from used_model_id")
    else:
        r.skip("entrypoint not importable outside the runtime (BedrockAgentCoreApp absent)")

    print("")


# ---------------------------------------------------------------------------
# Check 2: the deployed table matches config/bu-models.json
# ---------------------------------------------------------------------------
def check_live_config(r: Results, args):
    print("--- Check 2: deployed table matches the matrix (live) ---")

    if not os.path.exists(MATRIX_FILE):
        r.skip(f"{MATRIX_FILE} not found")
        print("")
        return

    try:
        import boto3
        from botocore.exceptions import BotoCoreError, ClientError
    except ImportError:
        r.skip("boto3 not installed")
        print("")
        return

    session = boto3.Session(profile_name=args.profile) if args.profile else boto3.Session()
    ddb = session.client("dynamodb", region_name=args.region)
    bedrock = session.client("bedrock", region_name=args.region)

    matrix = json.load(open(MATRIX_FILE))

    try:
        rows = {i["team"]["S"]: i for i in ddb.scan(TableName=TEAM_CONFIG_TABLE)["Items"]}
    except (BotoCoreError, ClientError) as e:
        r.skip(f"cannot read {TEAM_CONFIG_TABLE}: {e}")
        print("")
        return

    try:
        existing = {
            p["inferenceProfileArn"]
            for p in bedrock.list_inference_profiles(
                typeEquals="APPLICATION", maxResults=1000
            )["inferenceProfileSummaries"]
        }
    except (BotoCoreError, ClientError) as e:
        r.skip(f"cannot list inference profiles: {e}")
        existing = None

    seen_profiles = {}
    for bu in matrix["businessUnits"]:
        team = bu["team"]
        row = rows.get(team)
        if not row:
            r.fail(f"{team}: in the matrix but has no row in {TEAM_CONFIG_TABLE}")
            continue

        models = {k: v["S"].strip() for k, v in row.get("models", {}).get("M", {}).items()}
        want = {m["modelId"] for m in bu["models"]}
        if set(models) == want:
            r.ok(f"{team}: entitled to exactly {len(want)} model(s) as configured")
        else:
            r.fail(f"{team}: table has {sorted(models)}, matrix says {sorted(want)}")

        if row.get("default_model", {}).get("S") == bu["defaultModel"]:
            r.ok(f"{team}: default model matches the matrix")
        else:
            r.fail(f"{team}: default model is "
                   f"{row.get('default_model', {}).get('S')!r}, "
                   f"matrix says {bu['defaultModel']!r}")

        for model, arn in models.items():
            if arn != arn.strip() or " " in arn:
                r.fail(f"{team}/{model}: stored ARN has whitespace: {arn!r}")
            if existing is not None and arn not in existing:
                r.fail(f"{team}/{model}: profile does not exist: {arn}")
            # Two pairs sharing a profile would merge their spend invisibly.
            if arn in seen_profiles:
                r.fail(f"profile {arn.rsplit('/', 1)[-1]} is shared by "
                       f"{seen_profiles[arn]} and {team}/{model} — "
                       f"their costs would be indistinguishable")
            else:
                seen_profiles[arn] = f"{team}/{model}"

    if existing is not None:
        r.ok(f"all {len(seen_profiles)} configured profiles exist and are distinct")

    # Pricing is needed for the dashboard cost widgets.
    pricing = matrix.get("modelPricing", {})
    missing = sorted({m["modelId"] for bu in matrix["businessUnits"]
                      for m in bu["models"]} - set(pricing))
    if missing:
        r.fail(f"modelPricing missing for: {missing} — these would be excluded "
               f"from the estimated cost widgets")
    else:
        r.ok("every configured model has pricing for the cost widgets")

    print("")


def main():
    args = parse_args()
    r = Results()

    print("=" * 70)
    print("  Business-unit cost attribution and entitlement validation")
    print("=" * 70)
    print("")

    check_resolver(r)
    check_fallback_safety(r)

    if args.live:
        check_live_config(r, args)
    else:
        print("--- Check 2: deployed table matches the matrix (live) ---")
        r.skip("live checks not requested (pass --live)")
        print("")

    print("=" * 70)
    print(f"  passed {r.passed}   failed {r.failed}   skipped {r.skipped}")
    print("=" * 70)
    return 1 if r.failed else 0


if __name__ == "__main__":
    sys.exit(main())
