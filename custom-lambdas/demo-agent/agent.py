"""
AI Gateway POC — Demo Agent (AgentCore Runtime entrypoint)

A Strands-based IT support assistant hosted on AgentCore Runtime. It connects
to an AgentCore Gateway over MCP for tool discovery and invocation, using a
Cognito machine-to-machine (client_credentials) bearer token. Tools available
through the gateway:
  - search-kb___search_kb        : Search the knowledge base
  - create-ticket___create_ticket: Create a (mock) ServiceNow incident ticket

The agent reasons with Claude Sonnet 4.6 (cross-region inference profile).

Runtime contract (AgentCore Runtime, HTTP protocol):
  - Listens on 0.0.0.0:8080
  - POST /invocations  -> handled by @app.entrypoint
  - GET  /ping         -> health check (provided by BedrockAgentCoreApp)

Environment variables (injected by deploy-demo-agent.sh from .agentcore-config.json):
  GATEWAY_MCP_URL        Gateway MCP endpoint (…/mcp)
  GATEWAY_CLIENT_ID      Cognito M2M app client id
  GATEWAY_CLIENT_SECRET  Cognito M2M app client secret (OMITTED when
                         GATEWAY_OAUTH_PROVIDER is set — the secret then lives in
                         the AgentCore Identity token vault, not the environment)
  GATEWAY_TOKEN_ENDPOINT Cognito token endpoint (…/oauth2/token)
  GATEWAY_SCOPE          OAuth2 scope (e.g. ai-gateway/invoke)
  GATEWAY_OAUTH_PROVIDER (optional) AgentCore Identity OAuth2 provider name; when
                         set, tokens are fetched from the token vault
  AGENTCORE_MEMORY_ID    (optional) AgentCore Memory id for cross-session memory
  TEAM_CONFIG_TABLE      (optional) DynamoDB table mapping business unit + model ->
                         Application Inference Profile ARN. Defaults to
                         ai-gateway-team-config. When a request carries a business_unit,
                         the agent resolves it to that team's profile for the requested
                         model, so Bedrock token metrics are attributed to the BU — the
                         same table and mechanism the API Gateway streaming proxy uses.
                         The row's models map doubles as a per-BU model allow-list.
  DEFAULT_BUSINESS_UNIT  (optional) business unit charged when a caller does not supply
                         one. Without it such turns are unattributed. A caller-supplied
                         business_unit always wins.
  AWS_REGION             AWS region (default us-east-1)

Local interactive use (outside Runtime):
  Set the env vars above, then:  python agent.py
  Memory persists per actor/session — override with AGENT_ACTOR_ID / AGENT_SESSION_ID.
  Set AGENT_BUSINESS_UNIT to exercise per-BU cost attribution locally.
"""

import os
import re
import sys
from datetime import datetime, timedelta

import boto3
import httpx
from strands import Agent
from strands.models.bedrock import BedrockModel
from strands.tools.mcp.mcp_client import MCPClient
from mcp.client.streamable_http import streamablehttp_client

try:
    # Present in the AgentCore Runtime container image.
    from bedrock_agentcore import BedrockAgentCoreApp
    _HAS_RUNTIME = True
except ImportError:  # Allows local `python agent.py` without the runtime package.
    BedrockAgentCoreApp = None
    _HAS_RUNTIME = False

try:
    # AgentCore Memory integration for Strands (bedrock-agentcore[strands-agents]).
    from bedrock_agentcore.memory.integrations.strands.config import (
        AgentCoreMemoryConfig,
        RetrievalConfig,
    )
    from bedrock_agentcore.memory.integrations.strands.session_manager import (
        AgentCoreMemorySessionManager,
    )
    _HAS_MEMORY = True
except ImportError:  # Memory is optional; agent still runs without it.
    AgentCoreMemoryConfig = RetrievalConfig = AgentCoreMemorySessionManager = None
    _HAS_MEMORY = False


# Fallback model used when a request carries no business unit, or the BU has no
# Application Inference Profile configured. Traffic on this ID lands in the
# "General" (unattributed) series on the CloudWatch dashboard.
MODEL_ID = "us.anthropic.claude-sonnet-4-6"

# DynamoDB table mapping business unit -> Application Inference Profile ARN.
# Same table the API Gateway streaming proxy reads, so chat and agent traffic
# share one source of truth for BU routing.
TEAM_CONFIG_TABLE = os.environ.get("TEAM_CONFIG_TABLE", "ai-gateway-team-config")

# Business unit charged when a caller does not name one.
#
# Without this, a payload omitting business_unit falls back to the raw MODEL_ID and its
# spend lands in the unattributed "General" pool. Setting it means agent traffic is
# attributed by default while a caller-supplied business_unit still takes precedence, so
# multi-BU attribution is preserved.
#
# Deliberately a business unit name and not an inference profile ARN: the ARN is resolved
# through TEAM_CONFIG_TABLE like every other lookup, which keeps one source of truth and
# means the entitlement rules apply to the default too.
DEFAULT_BUSINESS_UNIT = os.environ.get("DEFAULT_BUSINESS_UNIT", "").strip()

SYSTEM_PROMPT = """You are a AI Gateway IT Support Assistant. Your role is to help employees
with IT-related questions and issues by searching the internal knowledge base and creating
support tickets when needed.

Guidelines:
- Always search the knowledge base FIRST when a user asks a question. Provide relevant
  information from the KB results before suggesting other actions.
- Only create a ticket when the user EXPLICITLY requests one (e.g., "create a ticket",
  "open an incident", "file a request"). Do not proactively create tickets.
- When creating tickets, extract the title, priority (P1-P4), and description from the
  user's request. If priority is not specified, default to P3.
- Be concise and professional in your responses.
- If the knowledge base doesn't have relevant results, let the user know and offer to
  create a support ticket for further assistance.
"""


# ---------------------------------------------------------------------------
# Gateway authentication (Cognito M2M client_credentials) with token caching
# ---------------------------------------------------------------------------
# NOTE: this cache is not synchronized. BedrockAgentCoreApp handles one
# /invocations request at a time per runtime worker, so concurrent access does
# not occur in practice. Under a race the worst case is a redundant token fetch,
# not a correctness bug. If the runtime is ever made concurrent, guard the
# read/write below with a threading.Lock.
_token_cache = {"token": None, "expires_at": None}


def _get_gateway_url() -> str:
    """The gateway MCP endpoint — always required, regardless of auth mode."""
    url = os.environ.get("GATEWAY_MCP_URL")
    if not url:
        raise RuntimeError("Missing required gateway env var: GATEWAY_MCP_URL")
    return url


def _get_gateway_config():
    """Read gateway connection settings from environment variables."""
    url = os.environ.get("GATEWAY_MCP_URL")
    client_id = os.environ.get("GATEWAY_CLIENT_ID")
    client_secret = os.environ.get("GATEWAY_CLIENT_SECRET")
    token_endpoint = os.environ.get("GATEWAY_TOKEN_ENDPOINT")
    scope = os.environ.get("GATEWAY_SCOPE")

    missing = [
        name
        for name, val in [
            ("GATEWAY_MCP_URL", url),
            ("GATEWAY_CLIENT_ID", client_id),
            ("GATEWAY_CLIENT_SECRET", client_secret),
            ("GATEWAY_TOKEN_ENDPOINT", token_endpoint),
            ("GATEWAY_SCOPE", scope),
        ]
        if not val
    ]
    if missing:
        raise RuntimeError(f"Missing required gateway env vars: {', '.join(missing)}")

    return url, client_id, client_secret, token_endpoint, scope


def get_oauth_token() -> str:
    """Return a cached or freshly minted Cognito M2M access token.

    Prefers AgentCore Identity: when GATEWAY_OAUTH_PROVIDER is set and the
    identity SDK is available, the token is fetched from the AgentCore token
    vault (the client secret lives in the vault, not in the environment). Falls
    back to a direct Cognito client_credentials request using GATEWAY_CLIENT_*
    env vars (used for local runs outside AgentCore Runtime).
    """
    now = datetime.now()
    if _token_cache["token"] and _token_cache["expires_at"] and now < _token_cache["expires_at"]:
        return _token_cache["token"]

    provider = os.environ.get("GATEWAY_OAUTH_PROVIDER")
    scope = os.environ.get("GATEWAY_SCOPE")
    if provider:
        token = _get_token_via_identity(provider, scope)
        if token:
            # Vault-issued tokens: cache conservatively (50 min).
            _token_cache["token"] = token
            _token_cache["expires_at"] = now + timedelta(seconds=3000)
            return token
        # Fall through to direct M2M if the vault path is unavailable (e.g. local).

    _, client_id, client_secret, token_endpoint, scope = _get_gateway_config()

    resp = httpx.post(
        token_endpoint,
        data={
            "grant_type": "client_credentials",
            "client_id": client_id,
            "client_secret": client_secret,
            "scope": scope,
        },
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        timeout=30,
    )
    if resp.status_code != 200:
        raise RuntimeError(f"Failed to get OAuth token: {resp.status_code} - {resp.text}")

    data = resp.json()
    token = data["access_token"]
    # Refresh 5 minutes before actual expiry.
    expires_in = max(int(data.get("expires_in", 3600)) - 300, 60)
    _token_cache["token"] = token
    _token_cache["expires_at"] = now + timedelta(seconds=expires_in)
    return token


def _get_token_via_identity(provider_name: str, scope: str):
    """Fetch a gateway token from the AgentCore Identity token vault.

    Uses the 2-legged (M2M / client_credentials) OAuth2 flow against the
    credential provider created by setup-agentcore-identity.py. Returns None if
    the identity SDK isn't installed or no workload identity context is
    available (e.g. running locally outside AgentCore Runtime), so the caller
    can fall back to the direct client_credentials request.
    """
    # asyncio.run() below assumes we're called from a synchronous context. The
    # AgentCore Runtime entrypoint (`invoke`) is a sync function, so no event loop
    # is already running. If this is ever called from inside an async loop,
    # asyncio.run() raises RuntimeError, which the broad except handles by falling
    # back to the direct client_credentials request.
    try:
        import asyncio
        from bedrock_agentcore.identity.auth import requires_access_token

        @requires_access_token(
            provider_name=provider_name,
            scopes=[scope] if scope else [],
            auth_flow="M2M",
        )
        async def _fetch(*, access_token: str) -> str:
            return access_token

        return asyncio.run(_fetch())
    except Exception as e:  # noqa: BLE001 — identity is optional; fall back.
        print(f"  (identity token vault unavailable, using direct M2M: {e})", file=sys.stderr)
        return None


def get_mcp_client() -> MCPClient:
    """Build an MCP client pointed at the AgentCore Gateway with a bearer token."""
    gateway_url = _get_gateway_url()
    access_token = get_oauth_token()
    return MCPClient(
        lambda: streamablehttp_client(
            gateway_url,
            headers={"Authorization": f"Bearer {access_token}"},
        )
    )


# ---------------------------------------------------------------------------
# Business-unit cost attribution (business unit -> Application Inference Profile)
# ---------------------------------------------------------------------------
# AIP ARN cache: maps (business_unit, model) -> (arn, expiry_time).
# Caching avoids a DynamoDB GetItem on every invocation for config that rarely
# changes (BU -> AIP ARN mapping). The TTL caps the window in which a budget
# block takes effect — a BU that goes over budget will still be served until
# its cache entry expires. Lower TTL = faster enforcement, more DynamoDB reads.
# Higher TTL = fewer reads, but more cost can spill over after a budget breach
# before the block kicks in.
#
# 60 seconds is the default: the SpendAggregatorLambda runs on a schedule and
# writes month_spend periodically, so sub-minute enforcement is not meaningful
# anyway. Increase with caution — the trade-off is cost spillover.
_AIP_CACHE_TTL_SECONDS = 60
_aip_cache: dict = {}   # (business_unit, model) -> (arn, expires_at: datetime)
_dynamodb_client = None


class InactiveBusinessUnitError(RuntimeError):
    """Raised when a business unit exists in config but is marked inactive.

    Mirrors the 403 the API Gateway streaming proxy returns, so an unprovisioned
    BU cannot spend model budget through the agent path either.
    """


def _get_dynamodb():
    global _dynamodb_client
    if _dynamodb_client is None:
        region = os.environ.get("AWS_REGION", "us-east-1")
        _dynamodb_client = boto3.client("dynamodb", region_name=region)
    return _dynamodb_client


class ModelNotEntitledError(RuntimeError):
    """Raised when a business unit requests a model it is not entitled to.

    The models map on a team row is an allow-list, so entitlement and cost
    attribution are configured in the same place.
    """


class BudgetExceededError(RuntimeError):
    """Raised when a business unit has exceeded its monthly spend budget.

    Mirrors the 429 the API Gateway streaming proxy returns, so spend-cap
    enforcement applies to the agent path as well as the chat path.
    """


def resolve_model_id(business_unit: str = None, model: str = None) -> str:
    """Return the model id to reason with for this business unit and model request.

    Looks the BU up in TEAM_CONFIG_TABLE and returns the Application Inference
    Profile ARN for the requested model. Bedrock then emits
    InputTokenCount/OutputTokenCount under that profile, which is the dimension the
    CloudWatch dashboard slices per business unit.

    An AIP wraps exactly one model, so a BU using several models has one profile per
    model, held in the row's `models` map keyed by model id.

    Resolution order:
      - no business unit given            -> DEFAULT_BUSINESS_UNIT if set
      - still no business unit            -> raw MODEL_ID, unattributed
      - BU inactive                       -> InactiveBusinessUnitError
      - model given and in models map     -> that model's profile
      - model given, map exists, no entry -> ModelNotEntitledError
      - no model given                    -> default_model's profile, else aip_arn
      - legacy row with no models map     -> aip_arn, no entitlement check

    Falls back to the raw MODEL_ID when the BU has no row or the lookup fails, so a
    config problem degrades attribution rather than breaking the request.
    """
    business_unit = (business_unit or "").strip() or DEFAULT_BUSINESS_UNIT
    model = (model or "").strip()
    if not business_unit:
        return MODEL_ID

    cache_key = (business_unit, model)
    cached = _aip_cache.get(cache_key)
    if cached and datetime.now() < cached[1]:
        return cached[0]

    try:
        item = _get_dynamodb().get_item(
            TableName=TEAM_CONFIG_TABLE,
            Key={"team": {"S": business_unit}},
        ).get("Item")
    except Exception as e:  # noqa: BLE001 — attribution is best-effort, never fatal.
        print(
            f"  (team config lookup failed for '{business_unit}', "
            f"using default model: {e})",
            file=sys.stderr,
        )
        return MODEL_ID

    if not item:
        print(
            f"  (business unit '{business_unit}' not in {TEAM_CONFIG_TABLE} — "
            f"using default model)",
            file=sys.stderr,
        )
        return MODEL_ID

    # An explicit active=false is a deny; a missing active flag is treated as
    # not-provisioned and denied too, matching the proxy's conservative default.
    if item.get("active", {}).get("BOOL") is not True:
        raise InactiveBusinessUnitError(
            f"Business unit '{business_unit}' is not provisioned for AI Gateway access"
        )

    # ── Budget check ──────────────────────────────────────────────────────────
    # Mirrors the streaming proxy Lambda's check exactly.
    # budget_limit = 0 or absent → enforcement disabled (unlimited).
    # month_key tracks the billing period (YYYY-MM). If the stored month differs
    # from the current month the counter is stale — treat as 0 rather than
    # blocking the team for a previous period's spend.
    budget_limit = float(item.get("budget_limit", {}).get("N", "0") or "0")
    if budget_limit > 0:
        current_month = datetime.now().strftime("%Y-%m")
        stored_month = item.get("month_key", {}).get("S", "")
        month_spend = (
            float(item.get("month_spend", {}).get("N", "0") or "0")
            if stored_month == current_month
            else 0.0
        )
        if month_spend >= budget_limit:
            raise BudgetExceededError(
                f"Business unit '{business_unit}' has exceeded its monthly budget "
                f"(${month_spend:.4f} / ${budget_limit:.2f}). "
                f"Budget resets on the 1st of next month."
            )
        print(
            f"  Budget check OK: {business_unit} ${month_spend:.4f} / ${budget_limit:.2f}",
            file=sys.stderr,
        )

    # ARNs are trimmed on read. Bedrock rejects a model id with surrounding whitespace
    # as "The provided model identifier is invalid", which reads like a bad ARN rather
    # than a bad string, so a hand-edited row with a stray space is painful to debug.
    models = {
        k: v.get("S", "").strip()
        for k, v in item.get("models", {}).get("M", {}).items()
    }
    default_arn = item.get("aip_arn", {}).get("S", "").strip()

    if models:
        wanted = model or item.get("default_model", {}).get("S", "").strip()
        arn = models.get(wanted)
        if not arn:
            raise ModelNotEntitledError(
                f"Business unit '{business_unit}' is not entitled to model "
                f"'{wanted}'. Entitled models: {', '.join(sorted(models)) or 'none'}"
            )
    else:
        # Legacy row predating the models map: single profile, no entitlement check.
        arn = default_arn

    if not arn:
        print(
            f"  (business unit '{business_unit}' has no usable profile — "
            f"using default model)",
            file=sys.stderr,
        )
        return MODEL_ID

    _aip_cache[cache_key] = (arn, datetime.now() + timedelta(seconds=_AIP_CACHE_TTL_SECONDS))
    return arn


def _build_model(model_id: str = None) -> BedrockModel:
    region = os.environ.get("AWS_REGION", "us-east-1")
    return BedrockModel(model_id=model_id or MODEL_ID, region_name=region)


def _build_session_manager(session_id: str, actor_id: str):
    """Return an AgentCore Memory session manager, or None if memory is off.

    When AGENTCORE_MEMORY_ID is set and the integration package is available,
    the agent persists conversation events to AgentCore Memory and retrieves
    long-term memory (preferences, facts) relevant to the current turn.
    """
    memory_id = os.environ.get("AGENTCORE_MEMORY_ID")
    if not memory_id or not _HAS_MEMORY:
        return None

    region = os.environ.get("AWS_REGION", "us-east-1")
    # Pull long-term memories from the strategies created by setup-agentcore-memory.py.
    retrieval = {
        "/preferences/{actorId}": RetrievalConfig(top_k=5, relevance_score=0.5),
        "/facts/{actorId}": RetrievalConfig(top_k=10, relevance_score=0.3),
    }
    config = AgentCoreMemoryConfig(
        memory_id=memory_id,
        session_id=session_id,
        actor_id=actor_id,
        retrieval_config=retrieval,
    )
    return AgentCoreMemorySessionManager(agentcore_memory_config=config, region_name=region)


def diagnose_model_access(model_id: str) -> dict:
    """Probe what this container can actually do with a given model id.

    Bedrock reports an unauthorized Application Inference Profile as
    "The provided model identifier is invalid", which is indistinguishable from a
    genuinely bad ARN. This returns the raw outcome of each call so the real cause
    is visible in the runtime logs. Diagnostic only — not on the normal path.
    """
    region = os.environ.get("AWS_REGION", "us-east-1")
    out = {"model_id": model_id, "region": region}

    try:
        out["caller"] = boto3.client("sts", region_name=region).get_caller_identity()["Arn"]
    except Exception as e:  # noqa: BLE001
        out["caller"] = f"{type(e).__name__}: {e}"

    try:
        prof = boto3.client("bedrock", region_name=region).get_inference_profile(
            inferenceProfileIdentifier=model_id
        )
        out["get_inference_profile"] = {
            "status": prof.get("status"),
            "type": prof.get("type"),
            "models": [m.get("modelArn") for m in prof.get("models", [])],
        }
    except Exception as e:  # noqa: BLE001
        out["get_inference_profile"] = f"{type(e).__name__}: {e}"

    msgs = [{"role": "user", "content": [{"text": "say ok"}]}]
    cfg = {"maxTokens": 16}
    br = boto3.client("bedrock-runtime", region_name=region)

    try:
        r = br.converse(modelId=model_id, messages=msgs, inferenceConfig=cfg)
        out["converse"] = f"OK {r['usage']}"
    except Exception as e:  # noqa: BLE001
        out["converse"] = f"{type(e).__name__}: {e}"

    try:
        r = br.converse_stream(modelId=model_id, messages=msgs, inferenceConfig=cfg)
        usage = None
        for ev in r["stream"]:
            if "metadata" in ev:
                usage = ev["metadata"].get("usage")
        out["converse_stream"] = f"OK {usage}"
    except Exception as e:  # noqa: BLE001
        out["converse_stream"] = f"{type(e).__name__}: {e}"

    return out


def _exception_chain(exc: Exception, limit: int = 5):
    """Yield exc and the exceptions it wraps, outermost first.

    Strands does not surface the botocore error directly: `event_loop_cycle` re-raises it
    as `EventLoopException`, which keeps the original on `.original_exception` and passes
    only `str(original)` to `Exception.__init__`. So the structured error code is reachable
    only by walking the chain, and a check that reads `.response` off the outermost
    exception silently never matches.
    """
    seen = set()
    current = exc
    for _ in range(limit):
        if current is None or id(current) in seen:
            return
        seen.add(id(current))
        yield current
        current = (getattr(current, "original_exception", None)
                   or getattr(current, "__cause__", None))


def _is_invalid_model_error(exc: Exception) -> bool:
    """True only for Bedrock rejecting the model id, not for any other failure.

    Bedrock reports a malformed or unusable model identifier as ValidationException with
    "The provided model identifier is invalid". Matching that is what separates a bad
    profile from a throttle, a tool error, or a mid-stream failure — none of which are
    safe to retry, because retrying re-runs the whole prompt.

    Checks the structured error code where it is reachable, and falls back to matching the
    message, because a wrapped exception may carry only the stringified original. Both
    halves require "model identifier", so a different ValidationException (a malformed
    request, say) does not qualify.

    Note: an *unauthorised* profile surfaces as AccessDeniedException, which is
    deliberately not retried — retrying would not help, and the permission gap should be
    visible rather than papered over by a silent downgrade.
    """
    for item in _exception_chain(exc):
        # `.response` is a dict on botocore errors, but other libraries use the same
        # attribute name for unrelated objects (httpx puts a Response there), so this
        # must not assume a mapping.
        response = getattr(item, "response", None)
        if isinstance(response, dict):
            code = response.get("Error", {}).get("Code", "")
            if code == "ValidationException" and "model identifier" in str(item):
                return True

    text = str(exc)
    return "ValidationException" in text and "model identifier" in text


def run_prompt(
    prompt: str,
    session_id: str = "local-session",
    actor_id: str = "local-user",
    model_id: str = None,
) -> tuple:
    """Run a single prompt through the agent with gateway tools (+ optional memory).

    model_id is normally an Application Inference Profile ARN resolved from the
    caller's business unit, so this turn's tokens are attributed to that BU.

    If the resolved AIP is rejected by Bedrock, the turn is retried once on the
    default model rather than failing. Attribution is a reporting concern; losing
    it should degrade the cost breakdown, not the user's answer. The downgrade is
    logged so it does not pass unnoticed.

    Returns (response_text, model_id_actually_used). The caller needs the second
    element to report attribution honestly: reporting the *resolved* profile would
    claim the turn was attributed even when the fallback above had fired, which is
    precisely the failure the attribution checks exist to catch.
    """
    mcp_client = get_mcp_client()
    with mcp_client:
        gateway_tools = mcp_client.list_tools_sync()

        def _run(mid):
            # A session manager binds to exactly one Agent: reusing one instance for
            # a second Agent in the same session raises SessionException
            # ("agent_id must be unique in a session"). Build a fresh one per attempt
            # so the fallback below cannot trip over the first attempt's manager.
            agent_kwargs = {
                "model": _build_model(mid),
                "system_prompt": SYSTEM_PROMPT,
                "tools": gateway_tools,
            }
            session_manager = _build_session_manager(session_id, actor_id)
            if session_manager is not None:
                agent_kwargs["session_manager"] = session_manager
                # Explicit log line so the CloudWatch "Memory Operations" dashboard
                # widget (which filters on "MEMORY_OP") has something to count.
                print(
                    f"MEMORY_OP session_id={session_id} actor_id={actor_id} "
                    f"memory_id={os.environ.get('AGENTCORE_MEMORY_ID', '?')}"
                )
            return str(Agent(**agent_kwargs)(prompt))

        try:
            return _run(model_id), model_id
        except Exception as e:  # noqa: BLE001
            # Retry ONLY when Bedrock rejected the model identifier itself.
            #
            # This deliberately does not retry on anything else. Retrying re-runs the
            # whole prompt, and this agent has a create_ticket tool, so retrying after a
            # throttle or a mid-stream failure could create a second ticket, spend a
            # second turn's tokens, and write the conversation to memory twice. An
            # invalid model identifier is rejected on the first model call, before any
            # tool can run, so this narrow case is safe to retry.
            if not _is_invalid_model_error(e) or not model_id or model_id == MODEL_ID:
                raise
            print(
                f"  (inference profile {model_id} rejected — falling back to "
                f"{MODEL_ID}; BU attribution lost for this turn: "
                f"{type(e).__name__}: {e})",
                file=sys.stderr,
            )
            print(f"  AIP diagnostics: {diagnose_model_access(model_id)}", file=sys.stderr)
            return _run(MODEL_ID), MODEL_ID


# ---------------------------------------------------------------------------
# AgentCore Runtime entrypoint
# ---------------------------------------------------------------------------
if _HAS_RUNTIME:
    app = BedrockAgentCoreApp()

    # Reject prompts larger than this to bound model cost/latency and guard
    # against oversized or malformed payloads reaching the Strands Agent.
    MAX_PROMPT_CHARS = 10_000

    @app.entrypoint
    def invoke(payload):
        """Entrypoint invoked by AgentCore Runtime on POST /invocations."""
        # Only accept a JSON object payload — reject strings, lists, null, etc.
        if not isinstance(payload, dict):
            return {"error": "Invalid payload: expected a JSON object with a 'prompt' field."}

        prompt = payload.get("prompt", "")
        if not isinstance(prompt, str):
            return {"error": "Invalid payload: 'prompt' must be a string."}
        prompt = prompt.strip()
        if not prompt:
            return {"error": "No 'prompt' provided in payload."}
        if len(prompt) > MAX_PROMPT_CHARS:
            return {"error": f"'prompt' too long: {len(prompt)} chars (max {MAX_PROMPT_CHARS})."}
        # session_id groups a conversation; actor_id identifies the user/team so
        # long-term memory (preferences, facts) is scoped per actor.
        session_id = payload.get("session_id") or f"session_{datetime.now().strftime('%Y%m%d%H%M%S')}"
        actor_id = payload.get("actor_id") or "default_user"
        # Sanitize actor_id: Memory API requires [a-zA-Z0-9][a-zA-Z0-9-_/]* — no @ or .
        actor_id = re.sub(r'[^a-zA-Z0-9\-_/]', '-', actor_id).strip('-') or "default_user"

        # business_unit drives cost attribution: it selects the team's Application
        # Inference Profile so this turn's tokens show up under that BU in
        # CloudWatch. NOTE: the runtime uses IAM (SigV4) inbound auth with no JWT
        # authorizer, so this value is asserted by the caller, not verified here.
        # Only IAM principals trusted to declare their own cost center should be
        # allowed to invoke the runtime. See docs/observability-guide.md.
        business_unit = payload.get("business_unit")
        if business_unit is not None and not isinstance(business_unit, str):
            return {"error": "Invalid payload: 'business_unit' must be a string."}

        # Optional. When omitted the BU's default_model is used. When given, it must be
        # a model the BU is entitled to, so the same config controls both which model
        # runs and which cost center the tokens land on.
        requested_model = payload.get("model")
        if requested_model is not None and not isinstance(requested_model, str):
            return {"error": "Invalid payload: 'model' must be a string."}

        try:
            model_id = resolve_model_id(business_unit, requested_model)
        except (InactiveBusinessUnitError, ModelNotEntitledError, BudgetExceededError) as e:
            print(f"REFUSED: {e}", file=sys.stderr)
            return {"error": str(e)}

        # The business unit actually charged: the caller's if supplied, otherwise the
        # deploy-time default. Reported so a caller can tell which one applied.
        effective_bu = (business_unit or "").strip() or DEFAULT_BUSINESS_UNIT or None

        # Run first, then report. `used_model_id` is what Bedrock was actually called
        # with, which differs from the resolved model_id when the fallback fired.
        # Reporting the resolved id here would claim attribution that did not happen.
        response_text, used_model_id = run_prompt(
            prompt, session_id=session_id, actor_id=actor_id, model_id=model_id
        )
        attributed = used_model_id != MODEL_ID

        # Log attribution per turn. The response carries these fields too, but only a log
        # line makes them queryable in the runtime log group, so "was this turn
        # attributed, and to whom" is answerable after the fact rather than only at the
        # call site.
        print(
            f"ATTRIBUTION business_unit={effective_bu or '<none>'} "
            f"model={requested_model or '<default>'} "
            f"profile={used_model_id.rsplit('/', 1)[-1]} "
            f"attributed={attributed}"
            + ("" if used_model_id == model_id else
               f" (DOWNGRADED from {model_id.rsplit('/', 1)[-1]})")
        )

        return {
            "response": response_text,
            "session_id": session_id,
            "actor_id": actor_id,
            "business_unit": effective_bu,
            "business_unit_source": (
                "payload" if (business_unit or "").strip()
                else ("default" if DEFAULT_BUSINESS_UNIT else "none")
            ),
            "requested_model": requested_model,
            "model_id": used_model_id,
            "resolved_model_id": model_id,
            "cost_attributed": attributed,
            "memory_enabled": bool(os.environ.get("AGENTCORE_MEMORY_ID")) and _HAS_MEMORY,
        }


# ---------------------------------------------------------------------------
# Local interactive loop (when run directly, not in the runtime)
# ---------------------------------------------------------------------------
def run_interactive_loop() -> None:
    # Stable IDs let memory persist across turns and across runs. Override with
    # AGENT_ACTOR_ID / AGENT_SESSION_ID to simulate different users/sessions.
    actor_id = os.environ.get("AGENT_ACTOR_ID", "local-user")
    session_id = os.environ.get("AGENT_SESSION_ID", "local-session")
    # Sanitize actor_id for Memory API compatibility
    actor_id = re.sub(r'[^a-zA-Z0-9\-_/]', '-', actor_id).strip('-') or "local-user"
    memory_on = bool(os.environ.get("AGENTCORE_MEMORY_ID")) and _HAS_MEMORY

    # AGENT_BUSINESS_UNIT / AGENT_MODEL exercise per-BU, per-model routing locally.
    business_unit = os.environ.get("AGENT_BUSINESS_UNIT")
    requested_model = os.environ.get("AGENT_MODEL")
    try:
        model_id = resolve_model_id(business_unit, requested_model)
    except (InactiveBusinessUnitError, ModelNotEntitledError) as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    print("=" * 60)
    print("  AI Gateway IT Support Assistant")
    print("  Strands SDK + AgentCore Gateway (MCP)")
    print(f"  Model: {model_id}")
    effective_bu = business_unit or DEFAULT_BUSINESS_UNIT
    print(f"  Cost attribution: {'BU=' + effective_bu if effective_bu else 'OFF (General)'}")
    print(f"  Memory: {'ON (actor=' + actor_id + ', session=' + session_id + ')' if memory_on else 'OFF'}")
    print("=" * 60)
    print("\nAsk me anything about IT support, or type 'quit' to exit.\n")

    while True:
        try:
            user_input = input("You: ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nGoodbye!")
            break
        if not user_input:
            continue
        if user_input.lower() in ("quit", "exit", "q"):
            print("Goodbye!")
            break
        try:
            reply, used_model_id = run_prompt(
                user_input, session_id=session_id, actor_id=actor_id, model_id=model_id
            )
            if used_model_id != model_id:
                print(f"\n  (attribution downgraded to {used_model_id})", file=sys.stderr)
            print(f"\nAssistant: {reply}\n")
        except Exception as e:  # noqa: BLE001 — surface errors to the operator
            print(f"\nError: {e}\n", file=sys.stderr)


def main() -> None:
    if _HAS_RUNTIME and os.environ.get("AGENTCORE_RUNTIME", "").lower() in ("1", "true"):
        # Start the HTTP server expected by AgentCore Runtime.
        app.run()
    else:
        run_interactive_loop()


if __name__ == "__main__":
    main()
