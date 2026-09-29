#!/usr/bin/env bash
# create-team-config-table.sh — Create and seed the business-unit routing table
#
# Reads the entitlement matrix from config/bu-models.json and the profile ARNs from
# .aip-map.json (written by create-aips.sh), then writes one row per business unit.
#
# Row shape:
#   team           (S, PK)  Cognito custom:team value / agent business_unit
#   active         (BOOL)   false denies the BU outright
#   cost_center    (S)
#   budget_limit   (N)      reporting only today, not enforced
#   default_model  (S)      used when the caller names no model
#   models         (M)      modelId -> Application Inference Profile ARN. Doubles as
#                           the per-BU model allow-list.
#   aip_arn        (S)      default model's ARN. Retained so a reader that predates
#                           the models map keeps working.
#   month_spend    (N)      running spend total for the current billing period (USD).
#                           Incremented atomically by the Streaming Proxy Lambda after
#                           each request. Reset to 0 on month rollover.
#   month_key      (S)      current billing period key e.g. "2025-08". Used by the
#                           Lambda to detect month rollover and treat a stale counter as 0.
#
# Usage:
#   ./scripts/create-team-config-table.sh [REGION] [PROFILE]
#
# Legacy positional form is still accepted and ignored, so older callers that passed
# two AIP ARNs do not break:
#   ./scripts/create-team-config-table.sh <ARN> <ARN> [REGION] [PROFILE]

set -euo pipefail

###############################################################################
# Parameters — tolerate the old <ARN> <ARN> [REGION] [PROFILE] signature
###############################################################################
ARGS=()
for a in "$@"; do
    case "$a" in
        arn:aws:bedrock:*) ;;   # legacy AIP ARN positional, now sourced from .aip-map.json
        "") ;;                  # a legacy ARN slot that resolved to nothing upstream
        *) ARGS+=("$a") ;;
    esac
done

REGION="${ARGS[0]:-us-east-1}"
PROFILE="${ARGS[1]:-}"

AWS_OPTS="--region ${REGION}"
if [ -n "$PROFILE" ]; then
    AWS_OPTS="${AWS_OPTS} --profile ${PROFILE}"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
MATRIX_FILE="$ROOT_DIR/config/bu-models.json"
AIP_MAP_FILE="$ROOT_DIR/.aip-map.json"
TABLE_NAME="ai-gateway-team-config"

command -v jq >/dev/null 2>&1 || { echo "❌ jq is required"; exit 1; }
[ -f "$MATRIX_FILE" ]  || { echo "❌ $MATRIX_FILE not found"; exit 1; }
[ -f "$AIP_MAP_FILE" ] || { echo "❌ $AIP_MAP_FILE not found — run scripts/create-aips.sh first"; exit 1; }

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   Seed business-unit routing table                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Table:  ${TABLE_NAME}"
echo "  Region: ${REGION}"
echo ""

###############################################################################
# Create table if absent
###############################################################################
TABLE_STATUS=$(aws dynamodb describe-table \
    --table-name "$TABLE_NAME" \
    ${AWS_OPTS} \
    --query "Table.TableStatus" \
    --output text 2>/dev/null || echo "NOT_FOUND")

if [ "$TABLE_STATUS" = "ACTIVE" ]; then
    echo "  ⏭️  Table already exists"
elif [ "$TABLE_STATUS" = "NOT_FOUND" ]; then
    echo "  Creating table..."
    aws dynamodb create-table \
        --table-name "$TABLE_NAME" \
        --attribute-definitions '[{"AttributeName":"team","AttributeType":"S"}]' \
        --key-schema '[{"AttributeName":"team","KeyType":"HASH"}]' \
        --billing-mode PAY_PER_REQUEST \
        --tags '[{"Key":"Application","Value":"AIGatewayPOC"},{"Key":"CostCenter","Value":"IT-Operations"}]' \
        ${AWS_OPTS} \
        --output text >/dev/null
    aws dynamodb wait table-exists --table-name "$TABLE_NAME" ${AWS_OPTS}
    echo "  ✅ Table created"
else
    echo "  ⏳ Table status ${TABLE_STATUS} — waiting..."
    aws dynamodb wait table-exists --table-name "$TABLE_NAME" ${AWS_OPTS}
fi

echo ""
echo "  Seeding business units..."

###############################################################################
# Build one DynamoDB item per business unit by joining the matrix to the ARNs.
#
# Any model in the matrix without a corresponding entry in .aip-map.json is dropped
# and reported, rather than silently written as an empty ARN.
###############################################################################
ITEMS=$(jq -n \
    --slurpfile matrix "$MATRIX_FILE" \
    --slurpfile aipmap "$AIP_MAP_FILE" '
    ($aipmap[0]) as $map
    | [ $matrix[0].businessUnits[]
        | . as $bu
        | ( [ $bu.models[]
              | . as $m
              | ( first($map[] | select(.team == $bu.team and .modelId == $m.modelId) | .arn) ) as $arn
              | select($arn != null)
              | {key: $m.modelId, value: {S: $arn}}
            ] | from_entries
          ) as $models
        | ( first($map[] | select(.team == $bu.team and .modelId == $bu.defaultModel) | .arn) ) as $defaultArn
        | select($defaultArn != null)
        | {
            team:          {S: $bu.team},
            active:        {BOOL: $bu.active},
            cost_center:   {S: $bu.costCenter},
            budget_limit:  {N: ($bu.budgetLimit | tostring)},
            default_model: {S: $bu.defaultModel},
            models:        {M: $models},
            aip_arn:       {S: $defaultArn},
            month_spend:   {N: "0"},
            month_key:     {S: (now | strftime("%Y-%m"))}
          }
      ]')

COUNT=$(echo "$ITEMS" | jq 'length')
EXPECTED=$(jq '.businessUnits | length' "$MATRIX_FILE")

if [ "$COUNT" = "0" ]; then
    echo "  ❌ No business units could be resolved. Is .aip-map.json stale?"
    exit 1
fi

# A business unit whose default model has no entry in .aip-map.json is dropped by the
# join above. Left unreported that is silent misattribution: the unit has no row, so its
# traffic falls through to the raw model and runs unattributed indefinitely, with nothing
# having failed. Name the missing units and exit non-zero.
if [ "$COUNT" != "$EXPECTED" ]; then
    echo "  ❌ Only ${COUNT} of ${EXPECTED} business units could be resolved."
    echo "     These have no profile for their default model in .aip-map.json:"
    jq -r -n \
        --slurpfile matrix "$MATRIX_FILE" \
        --argjson items "$ITEMS" '
        ($items | map(.team.S)) as $done
        | $matrix[0].businessUnits[] | select(.team as $t | ($done | index($t)) == null)
        | "       " + .team + " (default model: " + .defaultModel + ")"'
    echo "     Their traffic would run UNATTRIBUTED. Re-run scripts/create-aips.sh so"
    echo "     every business unit has a profile for its default model, then retry."
    exit 1
fi

for i in $(seq 0 $((COUNT - 1))); do
    ITEM=$(echo "$ITEMS" | jq -c ".[$i]")
    TEAM=$(echo "$ITEM" | jq -r '.team.S')
    NMODELS=$(echo "$ITEM" | jq '.models.M | length')

    aws dynamodb put-item \
        --table-name "$TABLE_NAME" \
        --item "$ITEM" \
        ${AWS_OPTS} >/dev/null

    echo "  ✅ ${TEAM} — ${NMODELS} model(s) entitled, default $(echo "$ITEM" | jq -r '.default_model.S')"
    echo "$ITEM" | jq -r '.models.M | to_entries[] | "        " + .key + "  ->  " + (.value.S | split("/") | last)'
done

echo ""
echo "  Verifying..."
ACTUAL=$(aws dynamodb scan --table-name "$TABLE_NAME" --select COUNT ${AWS_OPTS} --query "Count" --output text)
echo "  ✅ Table '${TABLE_NAME}' has ${ACTUAL} rows"
echo ""
echo "  TABLE_NAME=${TABLE_NAME}"
