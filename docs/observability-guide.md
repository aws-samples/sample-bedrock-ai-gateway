# Observability & Cost Tracking Guide

How the AI Gateway POC captures, tracks, and displays model usage, costs, and access patterns.

---

## Dashboard Overview

**Location:** AWS Console → CloudWatch → Dashboards → `<company-name>-ai-gateway-<stage>` (e.g. `anycompany-ai-gateway-poc`)

The dashboard provides a single-pane view of all AI Gateway activity. Every widget pulls from real AWS service metrics — no custom calculations, no sampling. What you see is what AWS bills you for.

---

## How Data Flows

```
User → Client UI → API Gateway → Lambda (Streaming Proxy) → Amazon Bedrock
           ↓              ↓                                        ↓
      (browser)     Access Logs                           AWS/Bedrock Metrics
                   (user identity,                        (auto-emitted by AWS)
                    IP, status)                                     ↓
                         ↓                              Invocation Logs
                    CloudWatch                          (token counts, model,
                    Logs Insights                        latency — we enabled)
                         ↓                                        ↓
                    ┌──────────────── Dashboard ──────────────────┘
```

---

## Widget Descriptions

### 1. Bedrock Invocations by Model (Bar Chart)

- **What it shows:** Total number of API calls to each Bedrock model in the selected time range
- **Source:** `AWS/Bedrock` namespace → `Invocations` metric, dimensioned by `ModelId`
- **How it works:** AWS automatically emits this metric every time any Bedrock model is called. Zero configuration needed — it's a native service metric.
- **Latency:** 1-2 minutes from request to dashboard visibility
- **What to tell the customer:** "This shows exactly how many times each model was invoked. It's the same data AWS uses for billing."

### 2. Input / Output Token Usage Over Time (Line Chart)

- **What it shows:** Token consumption over time — separate lines for input tokens (what you send) and output tokens (what the model generates)
- **Source:** `AWS/Bedrock` namespace → `InputTokenCount` and `OutputTokenCount` metrics
- **How it works:** Bedrock measures the actual tokenized length of every request and response. These are real token counts, not estimates.
- **Latency:** 1-2 minutes
- **What to tell the customer:** "Input tokens are your prompts. Output tokens are model responses. Cost scales linearly with these numbers. You can see usage patterns — peak hours, average load, anomalies."
- **Cost relevance:** Claude Sonnet 4 pricing is per-token. This chart directly correlates to spend.

### 3. Bedrock Latency p50 / p95 (Line Chart)

- **What it shows:** Response time distribution — p50 (median) and p95 (95th percentile)
- **Source:** `AWS/Bedrock` namespace → `InvocationLatency` metric with p50 and p95 statistics
- **How it works:** AWS measures end-to-end time from when Bedrock receives the request to when the full response is generated (for streaming, this is time to first token or full response depending on the metric variant).
- **Latency:** 1-2 minutes
- **What to tell the customer:** "p50 tells you what a typical user experiences. p95 tells you worst-case for 95% of users. If p95 spikes, investigate — could be longer prompts, model congestion, or token limits."

### 4. Estimated Daily Cost (Single Value)

- **What it shows:** Estimated daily spend on Bedrock
- **Source:** Custom metric namespace `GenAI/Observability` → `EstimatedCost`
- **Current status:** This widget requires a custom metric publisher (Lambda that calculates `tokens × price_per_token`). Not yet implemented — will show "No data."
- **Alternative for demo:** Point to the Token Usage chart and explain: "At current Claude Sonnet 4 pricing ($3/1M input tokens, $15/1M output tokens), you can calculate daily cost from the token counts shown above."

### 5. API Traffic: Total vs Errors (Line Chart)

- **What it shows:** Three lines on one chart — total requests, client errors (4XX: auth failures + rate limits), and server errors (5XX: Lambda failures, timeouts)
- **Source:** `AWS/ApiGateway` namespace → `Count`, `4XXError`, `5XXError` metrics
- **How it works:** AWS counts every request and categorizes responses by status code. 429 (rate limited) and 401/403 (auth failures) count as 4XX. Lambda crashes or timeouts count as 5XX.
- **Latency:** ~1 minute
- **What to tell the customer:** "The blue line is total traffic. When the orange line (4XX) spikes, users are hitting rate limits or auth issues. If the red line (5XX) appears, something broke server-side — check Lambda logs. Ideally you want blue going up and orange/red staying flat."

### 6. User Access Logs Rollup (Table)

- **What it shows:** Who accessed the API, from what IP, whether they were authenticated, and how many requests they made
- **Source:** CloudWatch Logs Insights query on `/aws/apigateway/ai-gateway-poc-access-logs`
- **How it works:** We configured the API Gateway stage to write a JSON access log for every request. The log includes the authenticated user's email (from Cognito token claims). The dashboard runs a Logs Insights query that groups by user + IP.
- **Latency:** 30-60 seconds
- **What to tell the customer:** "Every API request is logged with the user's identity. Unauthenticated attempts show as '-' with their IP. This is your audit trail — you can see who's using the system and catch unauthorized access attempts."

---

## Two Layers of Logging

### Layer 1: API Gateway Access Logs (user identity + access patterns)

```json
{
  "requestId": "b58c6bb6-ff70-412a-b369-28952af8e081",
  "ip": "198.51.100.42",
  "user": "user@example.com",
  "requestTime": "08/Jun/2026:20:37:51 +0000",
  "httpMethod": "POST",
  "path": "/v1/model/us.anthropic.claude-sonnet-4-6/converse-stream",
  "status": "200",
  "responseLength": "4554"
}
```

- **Purpose:** Who did what, when, from where
- **Log group:** `/aws/apigateway/ai-gateway-poc-access-logs`
- **Retention:** 30 days

### Layer 2: Bedrock Invocation Logs (token-level detail)

```json
{
  "modelId": "us.anthropic.claude-sonnet-4-6",
  "inputTokens": 42,
  "outputTokens": 156,
  "latencyMs": 2341,
  "timestamp": "2026-06-09T04:55:56Z"
}
```

- **Purpose:** Cost attribution, usage analytics, model performance
- **Log group:** `/aws/bedrock/ai-gateway-poc-invocations`
- **Retention:** 30 days
- **Configured by:** `scripts/enable-logging.py` (calls `PutModelInvocationLoggingConfiguration`)

---

## Per-BU Budget Enforcement

Each business unit has a `budget_limit` (USD/month) stored in the `ai-gateway-team-config` DynamoDB table. Spend is tracked asynchronously via the **SpendAggregatorLambda** — a fully event-driven, decoupled process that runs every 2 minutes independently of the Streaming Proxy Lambda.

**Architecture:**
```
EventBridge rate(2 minutes) → SpendAggregatorLambda
  ├── DynamoDB Scan → build team→profile mapping dynamically (no hardcoding)
  ├── CloudWatch GetMetricStatistics per AIP profile (AWS/Bedrock namespace)
  ├── Sum tokens × price per team
  └── DynamoDB UpdateItem: SET month_spend = total_cost, month_key = YYYY-MM

Streaming Proxy Lambda (pre-request only):
  └── DynamoDB GetItem: if month_spend >= budget_limit → HTTP 429
```

**Why this architecture:**
- The Streaming Proxy Lambda only **reads** DynamoDB — it cannot manipulate spend counters
- Any client that calls Bedrock through a team's AIP gets counted automatically
- Spend data comes from AWS infrastructure (`AWS/Bedrock` metrics) — the same source as the dashboard
- Adding a new team only requires updating DynamoDB — no Lambda code changes

- **Pre-request check**: reads `budget_limit` and `month_spend`; if `month_spend >= budget_limit > 0`, returns HTTP 429 with a JSON error body before calling Bedrock — no tokens consumed, no cost incurred.
- **Month auto-reset**: `BudgetResetLambda` runs at midnight UTC on the 1st via EventBridge `cron(0 0 1 * ? *)`. SpendAggregatorLambda also naturally resets since its CloudWatch window always starts from the 1st of the current month.
- **Interval**: configurable in the `SpendAggregatorSchedule` EventBridge rule (default: 2 minutes).

**Error response when budget exceeded (HTTP 429):**
```json
{
  "error": "Team 'Architecture' has exceeded its monthly budget ($0.0907 / $0.05). Budget resets on the 1st of next month."
}
```

The UI displays this as: `⛔ <message>. Please contact your administrator to increase your budget limit.`

**Check live spend counters (updated every 2 min):**
```bash
aws dynamodb scan --table-name ai-gateway-team-config \
  --projection-expression "team, budget_limit, month_spend, month_key" \
  --query "Items[].{team:team.S, limit:budget_limit.N, spend:month_spend.N, period:month_key.S}" \
  --output table --region us-east-1
```

**Change a team's budget limit (no redeploy needed):**
```bash
aws dynamodb update-item --table-name ai-gateway-team-config \
  --key '{"team":{"S":"Architecture"}}' \
  --update-expression "SET budget_limit = :bl" \
  --expression-attribute-values '{":bl":{"N":"5000"}}' --region us-east-1
```

**Manual reset (emergency / testing):**
```bash
bash scripts/reset-team-budgets.sh us-east-1
```

**Test enforcement end-to-end:**
```bash
python3 tests/test-budget-enforcement.py \
  --gateway-url "$GATEWAY_URL" --api-key "$API_KEY" \
  --user-pool-id "$USER_POOL_ID" --test-client-id "$TEST_CLIENT_ID" \
  --username "$COGNITO_USERNAME" --password "$COGNITO_PASSWORD"
```
This test sets a $0.01 temporary limit, sends requests until a 429 fires, verifies the error message, resets the spend, and confirms requests succeed again. It always restores the original budget state.

---

| Question | Answer |
|----------|--------|
| Are these metrics accurate? | Yes — they come directly from AWS service infrastructure. Same data used for billing. |
| Is there sampling? | No — every request is counted and logged. |
| Is it real-time? | Near real-time. Metrics: 1-2 min lag. Logs: 30-60 sec lag. |
| Can metrics be tampered with? | No — `AWS/Bedrock` and `AWS/ApiGateway` metrics are emitted by AWS internally. You can't write to these namespaces. |
| What about cost accuracy? | Token counts are exact. Cost = tokens × published price. No hidden overhead. |

---

## Cost Attribution

The POC uses two mechanisms for cost attribution:

1. **Bedrock Project Tags:** All invocations flow through a Bedrock Project tagged with `CostCenter: IT-Operations`. This allows filtering in AWS Cost Explorer by cost center.

2. **AWS Budget Alert:** A $500/month budget monitors the `CostCenter: IT-Operations` tag. At 80% ($400), an email alert fires to the configured address.

### Known Limitation: Cost Allocation Tag Visibility

The `CostCenter` tag is correctly applied to all resources (API Gateway, Lambda, S3, OpenSearch — verified via CLI). However, it may **not appear in the Cost Allocation Tags page** in the management/payer account for the following reasons:

1. **CUR processing delay** — AWS discovers user-defined tags from Cost and Usage Reports (CUR), which process once daily or at the end of the billing cycle. For new resources, this can take up to the first full billing period (end of month).

2. **Organization CUR dependency** — In AWS Organizations, the CUR is owned by the management/payer account. If CUR isn't configured, or hasn't processed since the tagged resources were created, tags won't appear in Cost Allocation Tags.

3. **Bedrock invocations aren't per-invocation tagged** — Even with tags on infrastructure (Lambda, API GW), Bedrock model invocations appear as a single service line item in Cost Explorer. The `CostCenter` tag helps filter infrastructure costs (Lambda execution, API Gateway requests, S3 storage, OpenSearch) but NOT the Bedrock model inference cost directly.

**What this means for the customer:**
- If they're in a fresh account or new Organization, tags appear after the first full billing cycle
- For Bedrock inference costs specifically, filter by `Service = Amazon Bedrock` in Cost Explorer — if only this POC uses Bedrock in the account, 100% of that line = POC cost
- The operational cost tracking (token counts on the dashboard) gives real-time cost visibility without relying on Cost Explorer tags

**Workaround for immediate cost visibility:**
- Use the dashboard's Token Usage chart + pricing math: `Input Tokens × $3/1M + Output Tokens × $15/1M = daily Bedrock cost`
- Use AWS Cost Explorer filtered by `Service = Amazon Bedrock` for the account-level Bedrock spend

### Activating Cost Allocation Tags (Manual Step — Management Account)

This step must be done once by someone with access to the **AWS Organization management/payer account**. It cannot be automated from the member account where the POC is deployed.

**Steps:**

1. Sign in to the **management/payer account** (not the POC account)
2. Go to **Billing** → **Cost Allocation Tags**
3. Click the **"User-defined cost allocation tags"** tab
4. Find `CostCenter` in the list → check the box → click **"Activate"**
5. (Optional) Also activate `Application` if you want to filter by app name
6. Wait **24 hours** for the tag to appear in Cost Explorer

**After 24 hours:**

1. Open **Cost Explorer** (in payer or member account)
2. Click **"Group by"** → select **Tag: CostCenter**
3. Add filter: **Tag: CostCenter** = `IT-Operations`
4. (Optional) Add filter: **Service** = `Amazon Bedrock`, `AWS Lambda`, `Amazon API Gateway`, `Amazon OpenSearch Service`
5. You'll see a cost breakdown per day, filtered to this POC's resources

**Demo talking points:**
- "We tag all resources with CostCenter: IT-Operations at deployment time"
- "Once activated in the management account, Cost Explorer shows spend filtered to this cost center — broken down by service"
- "Bedrock inference is the primary cost driver. Lambda and API Gateway add minimal overhead"
- "The dashboard gives real-time token visibility; Cost Explorer gives the financial attribution"

### Validating Per-BU Token Metrics (FR-002)

Invocations flow through an Application Inference Profile chosen from the caller's
business unit, and CloudWatch emits token metrics per profile. That gives per-BU cost
visibility in minutes rather than waiting on Cost Explorer tag propagation.

A profile wraps exactly one model, so there is one profile per **(business unit, model)**
pair rather than one per business unit. The matrix is declared in
`config/bu-models.json`:

```
Architecture    us.anthropic.claude-sonnet-4-6                 (default)
Architecture    us.anthropic.claude-haiku-4-5-20251001-v1:0
IT-Operations   us.anthropic.claude-sonnet-4-6                 (default)
IT-Operations   us.amazon.nova-lite-v1:0
```

The per-BU dashboard widgets sum a business unit's profiles into one series, so
"Architecture spend" stays a single line while remaining decomposable by model.

The model list is also an **allow-list**. A business unit requesting a model it is not
listed for is refused with a 403 on the chat plane, or an error on the agent plane, and
no model call is made — so no spend is incurred on a refused request. Entitlement and
chargeback are therefore configured in the same place and cannot drift apart.

Add a business unit or a model by editing `config/bu-models.json`, then re-running:

```bash
./scripts/create-aips.sh us-east-1          # creates any missing profiles
./scripts/create-team-config-table.sh us-east-1
python scripts/update-dashboard.py          # regenerates the per-BU widgets
```

Validate the wiring end to end with:

```bash
python tests/test-bu-cost-attribution.py --live
```

**CLI validation command:**
```bash
# Architecture team tokens (last 24h):
aws cloudwatch get-metric-statistics \
  --namespace "AWS/Bedrock" \
  --metric-name "InputTokenCount" \
  --dimensions "Name=ModelId,Value=<ARCHITECTURE_AIP_ID>" \
  --start-time "$(date -u -v-24H '+%Y-%m-%dT%H:%M:%SZ')" \
  --end-time "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --period 3600 --statistics Sum --region us-east-1

# IT-Operations team tokens (last 24h):
aws cloudwatch get-metric-statistics \
  --namespace "AWS/Bedrock" \
  --metric-name "InputTokenCount" \
  --dimensions "Name=ModelId,Value=<IT_OPERATIONS_AIP_ID>" \
  --start-time "$(date -u -v-24H '+%Y-%m-%dT%H:%M:%SZ')" \
  --end-time "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --period 3600 --statistics Sum --region us-east-1
```

**Get AIP IDs from DynamoDB:**
```bash
aws dynamodb scan --table-name ai-gateway-team-config \
  --query "Items[].{Team:team.S, AIP:aip_arn.S}" --output table
```

**Dashboard widget:** "Token Usage by Business Unit" shows separate lines per BU — visible immediately after invocations (1-2 min metric lag).

**How it works (chat plane):**
1. User logs in → Cognito token contains `custom:team` attribute
2. Streaming Proxy Lambda reads team from token claims
3. Lambda looks up team in DynamoDB `ai-gateway-team-config` → gets AIP ARN
4. Bedrock call uses the AIP ARN instead of the raw model ID
5. CloudWatch emits metrics under the AIP's short ID as the `ModelId` dimension
6. Dashboard filters by AIP ID to show per-BU split

**How it works (agent plane):**

The AgentCore Runtime agent uses the same table and the same AIP mechanism, so agent
tokens land on the same per-BU dashboard series as chat tokens. The difference is where
the business unit comes from:

1. Caller invokes the runtime with `business_unit` in the payload
2. `agent.py` `resolve_model_id()` looks the BU up in `ai-gateway-team-config`
3. The resolved AIP ARN is passed as `BedrockModel(model_id=...)`
4. Every model call in that turn — including tool-use round trips — is attributed to the BU
5. The response echoes `model_id` and `cost_attributed` so you can confirm attribution
   without leaving the invoke

```bash
echo '{"prompt":"How do I reset my VPN?","business_unit":"Architecture","actor_id":"alice"}' > /tmp/p.json
aws bedrock-agentcore invoke-agent-runtime \
  --agent-runtime-arn "$(jq -r .agentRuntimeArn .agentcore-config.json)" \
  --payload fileb:///tmp/p.json --region us-east-1 /dev/stdout
```

Behaviour matches the proxy: an unknown BU or a failed lookup falls back to the raw model
ID (the "General" series), and a BU with `active: false` is rejected rather than served.

> **Trust boundary.** The runtime uses IAM (SigV4) inbound auth with no JWT authorizer, so
> `business_unit` is *asserted by the caller*, not verified from a token claim the way the
> chat plane does it. Only IAM principals trusted to declare their own cost center should
> hold `bedrock-agentcore:InvokeAgentRuntime`. To make it verifiable, attach a Cognito JWT
> authorizer to the runtime and read `custom:team` from the validated token instead of the
> payload.

**Separating agent spend from chat spend.** Both planes share the same profile for a given
(business unit, model) pair, so the dashboard shows one combined number per business unit.
If you need to split them, add a second profile per BU for the agent path — for example a
`architecture-agent` entry in `config/bu-models.json` — and have the agent request that
model id. The dashboard generator picks up the new profile automatically.

**What to tell the customer:**
> "Every model invocation is routed through an inference profile specific to the caller's
> business unit and the model they asked for. That gives real-time token usage broken down
> by business unit and by model, on the dashboard within about two minutes of each call.
> No manual tagging — it derives from who the user is. The same config decides which
> models a business unit is allowed to use, so entitlement and chargeback never disagree.
> Onboarding a business unit is an edit to one config file."

### Known benign CloudFormation drift

Two properties on the gateway stack report as drifted permanently. Both are differences
in how AWS stores a value rather than real configuration drift, and neither should be
"fixed":

| Resource | Property | Why |
|---|---|---|
| `BedrockApiGatewayOptionsMethod` | `Integration/IntegrationResponses/0/ResponseTemplates` | The template declares `{"application/json": ""}`; API Gateway discards an empty response template and reports `null`. Removing it from the template risks breaking the MOCK integration on a fresh deploy. |
| `BedrockApiGatewayStage` | `AccessLogSetting/DestinationArn` | `!GetAtt AccessLogGroup.Arn` yields a `:*` suffix; API Gateway stores the ARN without it. |

Treat any drift beyond these two as real and worth investigating.

### The AOSS network policy hazard

The knowledge base returns `401` from `Retrieve` when the OpenSearch Serverless
collection's network policy does not permit the public endpoint, because Bedrock reaches
AOSS that way. The error mentions neither the network policy nor the endpoint, and IAM
and the data access policy can both be perfectly correct, so this is easy to misdiagnose.

If KB search starts returning 401, check this first:

```bash
aws opensearchserverless get-security-policy \
  --name ai-gateway-kb-net-poc --type network --region us-east-1 \
  --query "securityPolicyDetail.policy"
```

`AllowFromPublic` must be `true`, which is what `custom-lambdas/template.yaml` declares.
The live policy has been observed reverting to `false` with a placeholder
`SourceVPCEs` entry, so verify the live value rather than trusting the template.

---

## AgentCore Observability (Feature 4)

The demo IT Support Assistant runs on **Amazon Bedrock AgentCore** and uses four primitives:
the **Runtime** (the hosted agent), the **MCP Gateway** (tool calls), **Identity** (token vault),
**Memory** (cross-session persistence), and the **Agent Registry** (discovery). This section gives
CLI commands to validate each one from a terminal.

All commands read identifiers from `.agentcore-config.json` (written by the deploy scripts). The
snippets below export those values once so the rest can be copy-pasted:

```bash
REGION=$(jq -r .region .agentcore-config.json)
RUNTIME_ID=$(jq -r .agentRuntimeId .agentcore-config.json)
GATEWAY_ID=$(jq -r .gatewayId .agentcore-config.json)
MEMORY_ID=$(jq -r .memory.memoryId .agentcore-config.json)
REGISTRY_ID=$(jq -r .registry.registryId .agentcore-config.json)
WORKLOAD_IDENTITY=$(jq -r .identity.workloadIdentityName .agentcore-config.json)
OAUTH_PROVIDER=$(jq -r .identity.oauth2ProviderName .agentcore-config.json)
```

> **Note:** Some AgentCore data-plane APIs (registry search, memory records) require a recent
> boto3/botocore (≈ 1.43+). The bundled AWS CLI may predate them — if a command returns
> `Unknown command`, run the equivalent `setup-*`/`test-agentcore.py` Python helper instead.

### 1. Agent Runtime logs

- **What it shows:** Each agent invocation — the user prompt, model reasoning, tool calls, and the
  structured response (`response`, `session_id`, `actor_id`, `memory_enabled`).
- **Log group:** `/aws/bedrock-agentcore/runtime/<RUNTIME_ID>`

```bash
# Tail the runtime log group live
aws logs tail "/aws/bedrock-agentcore/runtime/$RUNTIME_ID" \
  --follow --region "$REGION"

# Find invocations and their errors in the last hour
aws logs filter-log-events \
  --log-group-name "/aws/bedrock-agentcore/runtime/$RUNTIME_ID" \
  --start-time "$(($(date +%s) - 3600))000" \
  --filter-pattern '?ERROR ?Exception ?response' \
  --region "$REGION"
```

- **What to tell the customer:** "Every agent turn is logged — you can see exactly which MCP tool
  the agent chose, the arguments it passed, and the answer it returned."

### 2. MCP Gateway logs

- **What it shows:** Tool invocations routed through the AgentCore Gateway (`search_kb`,
  `create_ticket`) — including auth, target Lambda, and latency.
- **Log group:** `/aws/bedrock-agentcore/gateways/<GATEWAY_ID>`

```bash
# Tail the gateway log group
aws logs tail "/aws/bedrock-agentcore/gateways/$GATEWAY_ID" \
  --follow --region "$REGION"

# If unsure of the exact log group name, list AgentCore groups:
aws logs describe-log-groups \
  --log-group-name-prefix "/aws/bedrock-agentcore" \
  --query "logGroups[].logGroupName" --output table --region "$REGION"
```

- **What to tell the customer:** "Tool calls are observable independently of the agent. You can
  confirm a knowledge-base search or a ticket creation actually hit the gateway."

### 3. Identity verification (workload identity + token vault)

- **What it shows:** That the agent has a workload identity and an OAuth2 credential provider in the
  token vault, so it fetches the gateway token from the vault instead of carrying a client secret.

```bash
# Confirm the workload identity exists
aws bedrock-agentcore-control get-workload-identity \
  --name "$WORKLOAD_IDENTITY" --region "$REGION"

# Confirm the OAuth2 credential provider (token vault entry) exists
aws bedrock-agentcore-control get-oauth2-credential-provider \
  --name "$OAUTH_PROVIDER" --region "$REGION"
```

- **What to tell the customer:** "The gateway client secret lives in the AgentCore token vault
  (backed by Secrets Manager), not in the agent's environment. The agent requests a short-lived
  token at call time."

### 4. Memory inspection (`list-events`, `retrieve-memory-records`)

- **What it shows:** Short-term conversation events and the long-term records extracted by the
  three strategies (`UserPreferences`, `Facts`, `SessionSummary`).

```bash
# Raw conversation events for a given actor/session (short-term memory)
aws bedrock-agentcore list-events \
  --memory-id "$MEMORY_ID" \
  --actor-id "<ACTOR_ID>" \
  --session-id "<SESSION_ID>" \
  --region "$REGION"

# Long-term extracted records via semantic retrieval (per namespace)
aws bedrock-agentcore retrieve-memory-records \
  --memory-id "$MEMORY_ID" \
  --namespace "/facts/<ACTOR_ID>" \
  --search-criteria '{"searchQuery":"printer issues"}' \
  --region "$REGION"
```

- **Namespaces** (from `.agentcore-config.json`):
  - Preferences → `/preferences/{actorId}`
  - Facts → `/facts/{actorId}`
  - Summaries → `/summaries/{actorId}/{sessionId}`
- **What to tell the customer:** "Use `list-events` to see the raw turns and
  `retrieve-memory-records` to see what the agent durably remembers about a user across sessions —
  preferences, facts, and per-session summaries."

### 5. Registry search (`search-registry-records`)

- **What it shows:** That the agent and its MCP tools are published to the Agent Registry and are
  semantically discoverable.

```bash
# Semantic discovery: should return the MCP tools record + the A2A agent record
aws bedrock-agentcore search-registry-records \
  --search-query "create an incident ticket" \
  --registry-ids "$REGISTRY_ID" \
  --max-results 5 --region "$REGION"

# List every record in the registry
aws bedrock-agentcore-control list-registry-records \
  --registry-id "$REGISTRY_ID" --region "$REGION"
```

- **What to tell the customer:** "The agent and its tools are cataloged in a governed registry.
  A natural-language query like 'create an incident ticket' surfaces the right MCP tool and agent
  record — that's how other teams discover and reuse them."

---

## Demo Script (for customer meeting)

### 1. Show the Dashboard (2 min)

Open the CloudWatch dashboard. Point out:
- "Here's your invocation volume — you can see every call to Claude Sonnet 4.6"
- "Token usage shows you're averaging X input tokens and Y output tokens per request"
- "Latency is consistent at p50 = ~2s, p95 = ~4s"

### 2. Show User Access (1 min)

Point to the User Access Logs table:
- "Every request is tied to an authenticated user — here you can see user@example.com made N requests"
- "Unauthenticated attempts are logged with their IP for security review"

### 3. Show Rate Limiting in Action (1 min)

Run the rate limiting test while the dashboard is open:
```bash
./tests/test-rate-limiting.sh <GATEWAY_URL> <API_KEY> <USER_POOL_ID> <TEST_CLIENT_ID> <USERNAME> <PASSWORD> <REGION>
```
Then refresh — the 4XX error line will spike with 429s.

### 4. Talk About Cost (1 min)

- "At Claude Sonnet 4 pricing: $3 per million input tokens, $15 per million output tokens"
- "Your 50 test invocations used ~X input tokens and ~Y output tokens = approximately $Z"
- "The budget alert at $500/month with 80% notification gives early warning before overspend"

### 5. Show the Raw Logs (optional, for security audience)

Open CloudWatch Logs Insights and run:
```
SOURCE '/aws/apigateway/ai-gateway-poc-access-logs'
| fields @timestamp, user, ip, httpMethod, path, status
| sort @timestamp desc
| limit 20
```

This shows the full audit trail in real-time.

---

## What's Not Yet Implemented

| Item | Status | What's needed |
|------|--------|---------------|
| Estimated Daily Cost widget | Shows "No data" | Build a Lambda that reads token counts, multiplies by price, publishes to `GenAI/Observability.EstimatedCost` custom metric |
| Per-user cost breakdown | Not built | Correlate Bedrock invocation logs (tokens) with access logs (user) via request ID |
| Alerting on anomalies | Not built | CloudWatch Alarms on sudden token usage spikes or error rate increases |
| ~~Per-BU budget enforcement~~ | ✅ **Implemented (Task 20)** | See "Per-BU Budget Enforcement" section above |

These are Phase 2 enhancements — the core observability (metrics, logging, access trail) is fully operational.
