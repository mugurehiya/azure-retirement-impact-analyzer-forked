#!/usr/bin/env bash

# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

set -o pipefail
QueriesFile="queries.txt"
OutputFile="impactedresources.csv"

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
NC='\033[0m'

# Validate dependencies
if ! command -v az >/dev/null 2>&1; then
    echo "Azure CLI 'az' is not installed or not found in PATH."
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "'jq' is required but not installed. Install it and rerun the script."
    echo "Example: sudo apt-get install jq"
    exit 1
fi

if [ ! -f "$QueriesFile" ]; then
    echo "Queries file not found: $QueriesFile"
    exit 1
fi

# Pre-install resource-graph extension silently
az extension add -n resource-graph --only-show-errors 2>/dev/null

az config set extension.dynamic_install_allow_preview=true --only-show-errors 2>/dev/null

TempDir="${TMPDIR:-/tmp}"
TempFile="$TempDir/arg-query-temp.kql"
AllResultsFile="$(mktemp "$TempDir/arg-results-XXXXXX.jsonl")"
QueryNumber=1

while IFS= read -r Query || [ -n "$Query" ]; do
    # Skip blank lines
    if [[ -z "${Query//[[:space:]]/}" ]]; then
        continue
    fi

    # Trim leading/trailing whitespace
    Query="$(echo "$Query" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    # Extract RetiringFeature from query
    RetiringFeature="Unknown"

    if [[ "$Query" =~ RetiringFeature[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
        RetiringFeature="${BASH_REMATCH[1]}"
    fi

    echo ""
    echo -e "${CYAN}=========== RetiringFeature : \"$RetiringFeature\" ===========${NC}"

    echo "$Query"
    echo "----------------------------------------------------------------"

    printf "%s" "$Query" > "$TempFile"
    SkipToken=""
    QueryResultsFile="$(mktemp "$TempDir/arg-query-results-XXXXXX.jsonl")"

    while true; do
        if [ -n "$SkipToken" ]; then
            Result="$(az graph query -q "@$TempFile" --skip-token "$SkipToken" -o json 2>/dev/null)"
        else
            Result="$(az graph query -q "@$TempFile" -o json 2>/dev/null)"
        fi

        # If az graph query fails or returns empty response, stop processing this query

        if [ -z "$Result" ]; then
            break
        fi

        # Append returned data rows
        echo "$Result" | jq -c '.data[]?' >> "$QueryResultsFile"

        # Get next skip token, if present
        SkipToken="$(echo "$Result" | jq -r '.skipToken // .skip_token // empty')"

        if [ -z "$SkipToken" ]; then
            break
        fi

    done

    ImpactedCount="$(wc -l < "$QueryResultsFile" | tr -d ' ')"

    if [ "$ImpactedCount" -eq 0 ]; then
        echo -e "${GREEN}No resources impacted${NC}"
    else
        echo -e "${GREEN}${ImpactedCount} resources impacted${NC}"
        # Print readable preview
        jq -r '.' "$QueryResultsFile"

        # Add metadata to each result for tracking
        jq -c --arg rf "$RetiringFeature" '
            . + {
                RetiringFeature: $rf,
                subscriptionId: (
                    (.id // "")
                    | capture("/subscriptions/(?<sub>[^/]+)/").sub // ""
                )
            }
        ' "$QueryResultsFile" >> "$AllResultsFile"
    fi

    rm -f "$QueryResultsFile"
    QueryNumber=$((QueryNumber + 1))

done < "$QueriesFile"
rm -f "$TempFile"

# Export results if output file specified
TotalResults="$(wc -l < "$AllResultsFile" | tr -d ' ')"

if [ -n "$OutputFile" ] && [ "$TotalResults" -gt 0 ]; then
    jq -r -s '
        if length == 0 then
            empty
        else
            (map(keys_unsorted) | add | unique) as $cols
            | $cols,
              (.[] | [ $cols[] as $c | .[$c] ])
            | @csv
        end
    ' "$AllResultsFile" > "$OutputFile"

    echo ""
    echo -e "${CYAN}Results exported to: $OutputFile${NC}"
    echo -e "${CYAN}Total resources: $TotalResults${NC}"
fi

rm -f "$AllResultsFile"