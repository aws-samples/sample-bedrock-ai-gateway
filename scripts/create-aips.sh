#!/usr/bin/env bash
# create-aips.sh — Create one Application Inference Profile per (business unit, model)
#
# An AIP wraps exactly one model, so attributing several models to a business unit
# requires one profile per pair. The matrix is declared in config/bu-models.json;
# this script reconciles it against what exists in the account.
#
# Each profile is tagged CostCenter/Team so Cost Explorer can roll spend up per BU
# across models, and per model across BUs.
#
# Usage:
#   ./scripts/create-aips.sh [REGION] [PROFILE]
#
# Outputs:
#   - .aip-map.json  : [{team, modelId, profileName, arn, isDefault}] for the seeder
#   - stdout         : AIP_<TEAM>=<arn> lines for each BU's default model, consumed by
#                      deploy.sh to fill in the CloudWatch dashboard
#
# Idempotent: existing profiles are reused, never duplicated.

set -euo pipefail

REGION="${1:-us-east-1}"
PROFILE="${2:-}"

AWS_OPTS="--region ${REGION}"
if [ -n "$PROFILE" ]; then
    AWS_OPTS="${AWS_OPTS} --profile ${PROFILE}"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
MATRIX_FILE="$ROOT_DIR/config/bu-models.json"
AIP_MAP_FILE="$ROOT_DIR/.aip-map.json"

command -v jq >/dev/null 2>&1 || { echo "❌ jq is required"; exit 1; }
[ -f "$MATRIX_FILE" ] || { echo "❌ $MATRIX_FILE not found"; exit 1; }

ACCOUNT_ID=$(aws sts get-caller-identity ${AWS_OPTS} --query Account --output text 2>/dev/null)

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   Application Inference Profiles per (business unit, model)   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Region: ${REGION}"
echo "  Matrix: config/bu-models.json"
echo ""

###############################################################################
# Cache the account's existing application profiles once.
#
# --type-equals APPLICATION is mandatory: list-inference-profiles returns only
# SYSTEM_DEFINED profiles by default. Omitting it makes every existence check miss
# and every run create another duplicate profile.
###############################################################################
# A failure here must not be swallowed. Treating an API error as "no profiles exist"
# makes every existence check miss, so the run creates a duplicate of every profile —
# which splits a business unit's spend across two ModelId dimensions and quietly
# understates it on the dashboard.
if ! EXISTING_JSON=$(aws bedrock list-inference-profiles \
    ${AWS_OPTS} \
    --type-equals APPLICATION \
    --max-results 1000 \
    --query "inferenceProfileSummaries[].{name:inferenceProfileName,arn:inferenceProfileArn}" \
    --output json 2>&1); then
    echo "❌ Could not list existing inference profiles:"
    echo "   ${EXISTING_JSON}"
    echo "   Refusing to continue: without this list every profile would be recreated,"
    echo "   splitting each business unit's spend across duplicate profiles."
    exit 1
fi

lookup_existing() {
    # `first(...)` guards against pre-existing duplicates returning several ARNs.
    echo "$EXISTING_JSON" | jq -r --arg n "$1" 'first(.[] | select(.name == $n) | .arn) // empty'
}

###############################################################################
# Create (or reuse) one profile
###############################################################################
RESULTS="[]"

create_aip() {
    local TEAM="$1" COST_CENTER="$2" MODEL_ID="$3" AIP_NAME="$4" IS_DEFAULT="$5"

    local ARN
    ARN="$(lookup_existing "$AIP_NAME")"

    if [ -n "$ARN" ]; then
        echo "  ⏭️  ${AIP_NAME}"
        echo "      reused: ${ARN}"
    else
        local MODEL_ARN="arn:aws:bedrock:${REGION}:${ACCOUNT_ID}:inference-profile/${MODEL_ID}"
        local TAG_JSON
        TAG_JSON=$(jq -nc --arg cc "$COST_CENTER" --arg team "$TEAM" --arg model "$MODEL_ID" \
            '[{key:"CostCenter",value:$cc},{key:"Team",value:$team},{key:"Model",value:$model}]')

        local RESULT
        RESULT=$(aws bedrock create-inference-profile \
            --inference-profile-name "${AIP_NAME}" \
            --model-source "{\"copyFrom\":\"${MODEL_ARN}\"}" \
            --tags "${TAG_JSON}" \
            ${AWS_OPTS} \
            --output json 2>&1) || {
            echo "  ❌ ${AIP_NAME}: create failed"
            echo "      ${RESULT}"
            return 1
        }

        ARN=$(echo "$RESULT" | jq -r '.inferenceProfileArn // .inferenceProfile.inferenceProfileArn // empty')
        if [ -z "$ARN" ]; then
            echo "  ❌ ${AIP_NAME}: could not read ARN from response"
            echo "      ${RESULT}"
            return 1
        fi
        echo "  ✅ ${AIP_NAME}"
        echo "      created: ${ARN}"
    fi

    echo "      team=${TEAM}  model=${MODEL_ID}  default=${IS_DEFAULT}"

    RESULTS=$(echo "$RESULTS" | jq -c \
        --arg team "$TEAM" --arg model "$MODEL_ID" --arg name "$AIP_NAME" \
        --arg arn "$ARN" --argjson isdef "$IS_DEFAULT" \
        '. + [{team:$team, modelId:$model, profileName:$name, arn:$arn, isDefault:$isdef}]')
}

###############################################################################
# Walk the matrix
###############################################################################
while IFS=$'\t' read -r TEAM COST_CENTER MODEL_ID AIP_NAME IS_DEFAULT; do
    [ -z "$TEAM" ] && continue
    create_aip "$TEAM" "$COST_CENTER" "$MODEL_ID" "$AIP_NAME" "$IS_DEFAULT"
done < <(jq -r '
    .businessUnits[] as $bu
    | $bu.models[]
    | [ $bu.team,
        $bu.costCenter,
        .modelId,
        .profileName,
        (if .modelId == $bu.defaultModel then "true" else "false" end)
      ] | @tsv' "$MATRIX_FILE")

echo "$RESULTS" | jq '.' > "$AIP_MAP_FILE"

echo ""
echo "  Wrote $(echo "$RESULTS" | jq 'length') profile mappings to .aip-map.json"
echo ""

###############################################################################
# Legacy stdout contract: one AIP_<TEAM>=<arn> line per BU default model.
# deploy.sh scrapes these to populate the CloudWatch dashboard.
###############################################################################
while IFS=$'\t' read -r KEY ARN; do
    echo "${KEY}=${ARN}"
done < <(echo "$RESULTS" | jq -r '
    .[] | select(.isDefault)
    | [ "AIP_" + (.team | ascii_upcase | gsub("-"; "_")), .arn ] | @tsv')

echo ""
echo "✅ AIP reconciliation complete."
