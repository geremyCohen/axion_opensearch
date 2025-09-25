#!/usr/bin/env bash
#
# set_replicas.sh TARGET TEMPLATE_NAME NUM_REPLICAS
#
# Deletes all indices and templates on TARGET, then creates a new composable
# index template TEMPLATE_NAME_template matching "TEMPLATE_NAME*"
# with the specified number_of_replicas.
#

set -euo pipefail

usage() {
  echo "Usage: $0 TARGET TEMPLATE_NAME NUM_REPLICAS"
  echo
  echo "Deletes ALL indices and templates, then creates a template"
  echo "named TEMPLATE_NAME_template matching \"TEMPLATE_NAME*\""
  echo "with settings.number_of_replicas=NUM_REPLICAS."
  echo
  echo "Arguments:"
  echo "  TARGET          Base URL of the cluster (e.g. http://10.0.0.203:9200)"
  echo "  TEMPLATE_NAME   Base name for the template (e.g. nyc_taxis)"
  echo "  NUM_REPLICAS    Integer replica count (e.g. 0, 1)"
  echo
  echo "Example:"
  echo "  $0 http://10.0.0.203:9200 nyc_taxis 0"
  exit 1
}

if [[ $# -lt 3 || "$1" == "-h" || "$1" == "--help" ]]; then
  usage
fi

TARGET="$1"
TEMPLATE_NAME="$2"
REPLICAS="$3"

echo "Target: $TARGET"
echo "Template to create: ${TEMPLATE_NAME}_template (index_patterns: \"${TEMPLATE_NAME}*\")"
echo "number_of_replicas: $REPLICAS"
echo

# --- Delete ALL indices ---
echo "Deleting ALL indices..."
curl -s -XDELETE "$TARGET/*" -H 'Content-Type: application/json' | jq .
echo "Done deleting indices."
echo

# --- Delete ALL templates ---
echo "Deleting ALL templates (legacy, composable, component)..."
curl -s -XDELETE "$TARGET/_template/*" -H 'Content-Type: application/json' | jq .
curl -s -XDELETE "$TARGET/_index_template/*" -H 'Content-Type: application/json' | jq .
curl -s -XDELETE "$TARGET/_component_template/*" -H 'Content-Type: application/json' | jq .
echo "Done deleting templates."
echo

# --- Create new template ---
echo "Creating template \"${TEMPLATE_NAME}_template\" with replicas=$REPLICAS for \"${TEMPLATE_NAME}*\"..."
curl -s -XPUT "$TARGET/_index_template/${TEMPLATE_NAME}_template" \
  -H 'Content-Type: application/json' \
  -d "{
    \"index_patterns\": [\"${TEMPLATE_NAME}*\"],
    \"template\": {
      \"settings\": {
        \"number_of_replicas\": $REPLICAS
      }
    }
  }" | jq .
echo

# --- Display the new template ---
echo "Fetching template \"${TEMPLATE_NAME}_template\"..."
curl -s "$TARGET/_index_template/${TEMPLATE_NAME}_template?pretty"
echo

echo "All done."