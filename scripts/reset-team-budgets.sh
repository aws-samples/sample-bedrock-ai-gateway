#!/usr/bin/env bash
# reset-team-budgets.sh — Manual emergency override to reset per-BU month_spend.
#
# Under normal operation, the BudgetResetLambda (deployed by gateway-stack.yaml)
# runs automatically on the 1st of each month via EventBridge cron(0 0 1 * ? *).
# The Streaming Proxy Lambda also auto-detects month rollover on every request.
#
# Use this script only when you need an immediate reset outside the scheduled window
# (e.g. after a misconfigured budget_limit, or to reset mid-month for testing).
#
# Usage:
#   ./scripts/reset-team-budgets.sh [REGION] [PROFILE]
#
# Example:
#   ./scripts/reset-team-budgets.sh us-east-1 webapps

set -euo pipefail

REGION="${1:-us-east-1}"
PROFILE="${2:-}"

AWS_OPTS="--region ${REGION}"
[ -n "$PROFILE" ] && AWS_OPTS="${AWS_OPTS} --profile ${PROFILE}"

TABLE_NAME="ai-gateway-team-config"
THIS_MONTH=$(date -u +"%Y-%m")

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   Reset per-BU monthly spend counters                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo "  Table:  ${TABLE_NAME}"
echo "  Region: ${REGION}"
echo "  Period: ${THIS_MONTH}"
echo ""

# Get all team names
TEAMS=$(aws dynamodb scan \
    --table-name "$TABLE_NAME" \
    --projection-expression "team" \
    --query "Items[].team.S" \
    --output json \
    $AWS_OPTS 2>/dev/null | jq -r '.[]')

if [ -z "$TEAMS" ]; then
    echo "  ⚠️  No teams found in table '${TABLE_NAME}' — nothing to reset"
    exit 0
fi

RESET_COUNT=0
SKIP_COUNT=0

while IFS= read -r team; do
    [ -z "$team" ] && continue

    # Read current month_key to see if reset is actually needed
    CURRENT_KEY=$(aws dynamodb get-item \
        --table-name "$TABLE_NAME" \
        --key "{\"team\":{\"S\":\"${team}\"}}" \
        --projection-expression "month_key, month_spend" \
        --query "Item" \
        --output json \
        $AWS_OPTS 2>/dev/null)

    STORED_KEY=$(echo "$CURRENT_KEY" | jq -r '.month_key.S // ""')
    STORED_SPEND=$(echo "$CURRENT_KEY" | jq -r '.month_spend.N // "0"')

    if [ "$STORED_KEY" = "$THIS_MONTH" ] && [ "$STORED_SPEND" = "0" ]; then
        echo "  ⏭️  ${team}: already at 0 for ${THIS_MONTH} — skipping"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    aws dynamodb update-item \
        --table-name "$TABLE_NAME" \
        --key "{\"team\":{\"S\":\"${team}\"}}" \
        --update-expression "SET month_spend = :zero, month_key = :mk" \
        --expression-attribute-values "{\":zero\":{\"N\":\"0\"},\":mk\":{\"S\":\"${THIS_MONTH}\"}}" \
        $AWS_OPTS >/dev/null

    echo "  ✅ ${team}: reset to 0 (was \$${STORED_SPEND} for period '${STORED_KEY:-unset}')"
    RESET_COUNT=$((RESET_COUNT + 1))
done <<< "$TEAMS"

echo ""
echo "  Reset: ${RESET_COUNT}  Skipped: ${SKIP_COUNT}"
echo ""
echo "  ✅ Budget reset complete. Period: ${THIS_MONTH}"
