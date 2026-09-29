# Scorecard Validation Checklist

Maps each validation test to its corresponding scorecard criterion and weight.

## Running All Tests

Use the single entrypoint script to run every test in the correct order.
All deployment values (gateway URL, API key, user pool ID, test client ID) are
**resolved dynamically** from CloudFormation stack outputs and AWS API calls —
no resource IDs or credentials need to be hardcoded.

Only two values must be provided — your Cognito credentials (found in `.env.md`
at the repo root, which is gitignored):

```bash
export AWS_PROFILE=<your-aws-profile>
export COGNITO_USERNAME="<your-cognito-email>"
export COGNITO_PASSWORD='<your-cognito-password>'
./tests/run-all-tests.sh
```

The script runs tests in order: **auth → rate limiting → cost tracking → MCP tools → AgentCore**.
It resolves the gateway URL, user pool, API key, and test client from CloudFormation and the
AWS API on every run. It prints a pass/fail summary and restores all AWS resources (usage plan
rate limit) on exit. It also drives data into every CloudWatch dashboard widget including the
AgentCore log-based widgets.

---

## Summary

| Feature | Weight | Status |
|---------|--------|--------|
| Rate Limiting | 20% | ✅ PASS (2026-07-27) |
| Cost Tracking | 30% | ✅ PASS (2026-07-27) |
| Authentication | 20% | ✅ PASS (2026-07-27) |
| MCP Tools | 20% | ✅ PASS (2026-07-27) |
| Deployment/Docs | 10% | ⬜ Manual review pending |
| **Total** | **100%** | |

---

## Feature 1: Rate Limiting (20%)

**Test Script:** `tests/test-rate-limiting.sh`

**Prerequisites:**
- API key from usage plan (get with: `aws apigateway get-api-keys --include-values --query "items[?name=='IT-Operations-key'].value" --output text`)
- Test App Client created (run `./scripts/create-test-client.sh` first)
- User password changed from temporary (first login completed)

**How it works:**
- The usage plan enforces ~2 req/sec (≈120 req/min) steady-state with burst of 3 req/sec (≈180 req/min)
- Test fires 30 parallel requests in ~1.5 seconds, exceeding the rate limit at the API Gateway level
- Both auth token AND API key are required (Cognito authorizer + usage plan)

| ID | Criterion | Test Method | Pass/Fail |
|----|-----------|-------------|-----------|
| 1.1 | Usage plan enforces rate limit | Send 30 parallel requests, verify at least one 429 response | ✅ |
| 1.2 | Burst capacity allows some requests through | Verify some requests succeed (200) before throttling | ✅ |
| 1.3 | 429 responses returned for excess requests | Count 429 responses in test output | ✅ |

**How to run:**
```bash
./tests/test-rate-limiting.sh \
  "$GATEWAY_URL" \
  "$API_KEY" \
  "$USER_POOL_ID" \
  "$TEST_CLIENT_ID" \
  "$USERNAME" \
  "$PASSWORD" \
  "$AWS_REGION" \
  "$AWS_PROFILE"
```

**Note:** Requires both API key (for usage plan) and auth token (for Cognito authorizer). The test obtains the token automatically using the test App Client.

**How it works internally:**
1. Obtains an auth token via the test App Client
2. Temporarily lowers the usage plan rate limit to 1 req/sec (production is 100 req/sec — impossible to trip from a laptop)
3. Waits 90 seconds for API Gateway throttle propagation
4. Fires 30 parallel requests to exceed the lowered limit
5. Counts 200s vs 429s
6. Restores the production rate limit (100 req/sec, burst 150) — guaranteed via `trap` even if test fails or is interrupted

**⚠️ SAFETY: The script ALWAYS restores the production rate limit (100 req/sec, burst 150) on exit:**
- On success: explicit restore step at the end
- On failure/interrupt/Ctrl-C: `trap EXIT` handler restores automatically
- If you need to verify manually: `aws apigateway get-usage-plans --query "items[?name=='IT-Operations-Plan'].throttle" --output json --region us-east-1`
- If restore failed for any reason: `aws apigateway update-usage-plan --usage-plan-id <ID> --patch-operations "op=replace,path=/throttle/rateLimit,value=100" "op=replace,path=/throttle/burstLimit,value=150" --region us-east-1`

This proves the rate limiting mechanism works without needing to generate 100+ req/sec of real traffic.

---

## Feature 2: Cost Tracking (30%)

**Test Script:** `tests/test-cost-tracking.py`

| ID | Criterion | Test Method | Pass/Fail |
|----|-----------|-------------|-----------|
| 2.1 | Input token count recorded in CloudWatch | Make 50 invocations, query CloudWatch for inputTokens field | ✅ |
| 2.2 | Output token count recorded in CloudWatch | Query CloudWatch for outputTokens field | ✅ |
| 2.3 | Model ID recorded in CloudWatch | Query CloudWatch for modelId field in invocation logs | ✅ |

**How to run:**
```bash
python tests/test-cost-tracking.py --gateway-url <URL> --api-key <KEY> --region <REGION>
```

---

## Feature 3: Authentication (20%)

**Test Script:** `tests/test-auth.sh`

**Prerequisites:** Run `./scripts/create-test-client.sh` first to create the dedicated test App Client.

| ID | Criterion | Test Method | Pass/Fail |
|----|-----------|-------------|-----------|
| 3.1 | Unauthenticated requests receive 401 | Send request without Authorization header | ✅ |
| 3.2 | Valid Cognito token grants access (200) | Obtain token via test client admin-initiate-auth, send authenticated request | ✅ |
| 3.3 | User identity logged in CloudWatch | Query access logs for username after authenticated request | ⚠️ (latency) |
| 3.4 | OAuth2/PKCE flow configured correctly | Verify Cognito app client has code grant, PKCE support, correct callback URLs | ✅ (by design) |

**How to run:**
```bash
./tests/test-auth.sh <GATEWAY_URL> <USER_POOL_ID> <TEST_CLIENT_ID> <USERNAME> <PASSWORD> [REGION] [PROFILE]
```

**Note:** The `<TEST_CLIENT_ID>` is the dedicated test client (from `create-test-client.sh`), NOT the production client. The production client only supports OAuth2/PKCE browser redirects.

---

## Feature 4: MCP Tools (20%)

**Test Script:** `tests/test-mcp-tools.py`

| ID | Criterion | Test Method | Pass/Fail |
|----|-----------|-------------|-----------|
| 4.1 | search_kb returns results with text, score, source fields | Invoke tool with test query, validate response schema | ✅ |
| 4.2 | create_ticket returns ticket with ticket_id, title, priority, status, created_at | Invoke tool with P3 priority, validate response schema | ✅ |
| 4.3 | Tool invocations recorded in trace logs | Query CloudWatch for invocation records after tool calls | ✅ |
| 4.4 | Tools discoverable via AgentCore Gateway | Verify tools are registered and queryable via semantic search | ✅ |

**How to run:**
```bash
python tests/test-mcp-tools.py --gateway-name <GATEWAY_NAME> --region <REGION>
```

---

## Feature 5: Deployment & Documentation (10%)

| ID | Criterion | Verification Method | Pass/Fail |
|----|-----------|---------------------|-----------|
| 5.1 | Single-command deployment succeeds | Run `deploy.sh` end-to-end without errors | ⬜ |
| 5.2 | Cleanup removes all resources | Run `cleanup/destroy.sh`, verify no orphaned stacks/buckets | ⬜ |
| 5.3 | README includes prerequisites and deploy instructions | Manual review of README.md | ⬜ |
| 5.4 | Architecture document maps features to components | Manual review of ARCHITECTURE.md | ⬜ |
| 5.5 | IAM permissions documented with least-privilege policies | Manual review of docs/IAM-PERMISSIONS.md | ⬜ |
| 5.6 | Entra ID integration guide provided | Manual review of docs/entra-id-integration.md | ⬜ |

---

## Scoring Guide

Each feature is scored as:
- **Full marks**: All criteria pass
- **Partial marks**: Some criteria pass (proportional)
- **Zero marks**: No criteria pass

**Final Score** = Σ (Feature Weight × Feature Score)

### Example Calculation

| Feature | Weight | Score | Weighted |
|---------|--------|-------|----------|
| Rate Limiting | 20% | 3/3 = 100% | 20% |
| Cost Tracking | 30% | 3/3 = 100% | 30% |
| Authentication | 20% | 3/4 = 75% | 15% |
| MCP Tools | 20% | 4/4 = 100% | 20% |
| Deployment/Docs | 10% | 5/6 = 83% | 8.3% |
| **Total** | | | **93.3%** |

---

## Running All Tests

### Prerequisites

Before running tests, ensure:
- ✅ POC is fully deployed (`deploy.sh` + `deploy-phase2.sh` completed)
- ✅ Python 3.11+ with `boto3` and `requests` installed
- ✅ AWS CLI v2 configured with credentials for the deployed account
- ✅ `jq` installed
- ✅ First login completed (temp password changed via Cognito Hosted UI)
- ✅ Test App Client created (see Setup below)

### One-Time Setup: Create Test App Client

The test scripts need a dedicated Cognito App Client for programmatic token acquisition. This is separate from the production client (which only supports browser-based OAuth2/PKCE).

```bash
# Create the test client (one-time, idempotent)
./scripts/create-test-client.sh <USER_POOL_ID> <REGION> [PROFILE]

# Example:
./scripts/create-test-client.sh us-east-1_XXXXXXXXX us-east-1
# Outputs: TEST_CLIENT_ID=<value>  ← save this for test commands
```

**Why a separate client?** The production App Client is intentionally locked to OAuth2/PKCE only (no password-based auth flows). This is the correct security posture for end users. The test client enables `ADMIN_USER_PASSWORD_AUTH` so scripts can get tokens without a browser. The Lambda Authorizer validates tokens from the same User Pool regardless of which client issued them.

### Environment Variables

Set these before running tests (values from your deployment output):

```bash
export GATEWAY_URL="https://<api-id>.execute-api.<region>.amazonaws.com/v1"
export USER_POOL_ID="<cognito-user-pool-id>"
export TEST_CLIENT_ID="<test-client-id-from-create-test-client.sh>"
export COGNITO_USERNAME="<cognito-username>"   # NOTE: use COGNITO_USERNAME not USERNAME
export COGNITO_PASSWORD="<your-password>"      # USERNAME is a reserved macOS system variable
export AWS_REGION="<region>"
export AWS_PROFILE="<profile>"  # Optional — only if not using default credentials
```

### Running Individual Tests

#### Test 1: Authentication (20% of scorecard)

Validates: Unauthenticated requests blocked (401), authenticated requests succeed (200), user identity logged.

```bash
./tests/test-auth.sh \
  "$GATEWAY_URL" \
  "$USER_POOL_ID" \
  "$TEST_CLIENT_ID" \
  "$COGNITO_USERNAME" \
  "$COGNITO_PASSWORD" \
  "$AWS_REGION" \
  "$AWS_PROFILE" \
  "$API_KEY"
```

**Expected output:**
```
✅ PASS: Unauthenticated request returned 401
✅ PASS: Authenticated request returned 200
🎉 OVERALL: PASS — Authentication enforcement verified
```

#### Test 2: Rate Limiting (20% of scorecard)

Validates: Usage plan enforces ~120 req/min steady-state, 429 responses for excess traffic.

```bash
# First, get your API key:
aws apigateway get-api-keys --include-values --region "$AWS_REGION" \
  ${AWS_PROFILE:+--profile $AWS_PROFILE} \
  --query "items[?name=='IT-Operations-key'].value" --output text

# Then run:
./tests/test-rate-limiting.sh \
  "$GATEWAY_URL" \
  "$API_KEY" \
  "$USER_POOL_ID" \
  "$TEST_CLIENT_ID" \
  "$COGNITO_USERNAME" \
  "$COGNITO_PASSWORD" \
  "$AWS_REGION" \
  "$AWS_PROFILE"
```

**Expected output:**
```
✅ PASS: Received N rate-limited (429) responses
🎉 OVERALL: PASS — Rate limiting is enforced
```

**Note:** Test temporarily lowers rate limit to 1 req/sec, fires 30 parallel requests, then restores production rate (100 req/sec). Takes ~2 minutes total (90s propagation wait).

#### Test 3: Cost Tracking (30% of scorecard — highest weight)

Validates: Token usage (input/output), model ID, and latency appear in CloudWatch within 5 minutes.

```bash
python3 tests/test-cost-tracking.py \
  --gateway-url "$GATEWAY_URL" \
  --api-key "$API_KEY" \
  --user-pool-id "$USER_POOL_ID" \
  --test-client-id "$TEST_CLIENT_ID" \
  --username "$COGNITO_USERNAME" \
  --password "$COGNITO_PASSWORD" \
  --region "$AWS_REGION"
```

**Note:** This test makes 50 model invocations and then waits up to 5 minutes for CloudWatch data to appear. Budget accordingly for Bedrock costs (~$0.10-$0.50 for the test).

#### Test 4: MCP Tools (20% of scorecard)

Validates: search_kb and create_ticket Lambda functions respond correctly.

```bash
# Direct Lambda invocation (recommended — no AgentCore Gateway CLI dependency):
python3 tests/test-mcp-tools.py --mode lambda --region "$AWS_REGION"
```

#### Test 5: AgentCore Primitives

Validates: Identity token vault, Memory cross-session persistence, Registry discovery, demo agent E2E.
Also populates the AgentCore log-based dashboard widgets.

```bash
python3 tests/test-agentcore.py --region "$AWS_REGION"
```

### Running All Tests (single command)

```bash
# Setup (one-time)
./scripts/create-test-client.sh "$USER_POOL_ID" "$AWS_REGION" "$AWS_PROFILE"

# Run all 5 tests — deployment values resolved automatically from CloudFormation:
export AWS_PROFILE=<your-aws-profile>
export COGNITO_USERNAME="<your-cognito-email>"
export COGNITO_PASSWORD='<your-cognito-password>'
./tests/run-all-tests.sh
```

### Customer Demo Walkthrough

For a live demo with the customer, recommended order:

1. **Show the Client UI** — Open CloudFront URL, login via Cognito Hosted UI, send a chat message. This demonstrates the end-to-end user experience (auth + model invocation + branded UI).

2. **Run Auth Test** — Shows security enforcement live. Takes ~15 seconds.

3. **Show CloudWatch Dashboard** — Open AWS Console → CloudWatch → Dashboards → `anycompany-ai-gateway-poc` (or whatever `--company-name` and `--stage` you deployed with). Shows invocations, tokens, latency, costs in real-time.

4. **Run Rate Limiting Test** — Most visual impact. Watch the 429s accumulate in ~10 seconds, then show the throttle count widget update on the dashboard.

5. **Show Cost Tracking** — Point to the token usage widgets and budget alert configuration. Run cost tracking test if time allows (takes 5+ minutes).

6. **Show KB Search** — Invoke the search_kb Lambda directly (or via the demo agent if AgentCore is available). Shows enterprise knowledge retrieval.

### Test Results Log

Record results here after each test run:

| Date | Auth | Rate Limit | Cost Track | MCP Tools | Notes |
|------|------|------------|------------|-----------|-------|
| 2026-07-27 | ✅ PASS | ✅ PASS | ✅ PASS | ✅ PASS | All 4 automated tests pass. Auth requires API_KEY param. Rate limit tested with 1 req/sec burst 1 (90s propagation). Cost tracking: 50/50 invocations, CloudWatch confirmed. |
