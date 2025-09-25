#!/usr/bin/env bash
set -euo pipefail

# set_replicas <TEMPLATE_NAME> <NUM_REPLICAS> [--url http://10.0.0.203:9200] [--user USER:PASS] [--insecure]
#
# Examples:
#   ./set_replicas nyc_taxis 0 --url http://10.0.0.203:9200
#   ./set_replicas logs 1 --url https://10.0.0.203:9200 --user admin:admin --insecure

usage() {
  cat <<EOF
Usage:
  $(basename "$0") <TEMPLATE_NAME> <NUM_REPLICAS> [--url URL] [--user USER:PASS] [--insecure]

Arguments:
  TEMPLATE_NAME     Base template name. The created template will be: <TEMPLATE_NAME>_template
                    It will apply to indices matching: "<TEMPLATE_NAME>*"
  NUM_REPLICAS      Integer for number_of_replicas (e.g. 0, 1, 2)

Options:
  --url URL         Base URL for the cluster (default: http://127.0.0.1:9200)
  --user USER:PASS  Basic auth "user:password" if security is enabled
  --insecure        Skip TLS verification (adds: -k to curl)
  -h, --help        Show this help message

Actions performed:
  1) DELETE all indices
  2) DELETE all templates (legacy, composable, and component)
  3) PUT a new composable index template "<TEMPLATE_NAME>_template" with number_of_replicas=<NUM_REPLICAS>
     and index_patterns=["<TEMPLATE_NAME>*"]
EOF
}

# ---------- Parse args ----------
if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

# Help flag handling
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
  esac
done

if [[ $# -lt 2 ]]; then
  echo "Error: Missing arguments." >&2
  usage
  exit 1
fi

TEMPLATE_NAME="$1"; shift
NUM_REPLICAS="$1"; shift

BASE_URL="http://127.0.0.1:9200"
CURL_AUTH_ARGS=()
CURL_TLS_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)
      BASE_URL="$2"; shift 2;;
    --user)
      CURL_AUTH_ARGS=(-u "$2"); shift 2;;
    --insecure)
      CURL_TLS_ARGS=(-k); shift 1;;
    *)
      echo "Unknown argument: $1" >&2
      usage; exit 1;;
  esac
done

# ---------- Helpers ----------
curl_json() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  if [[ -n "$data" ]]; then
    curl -sS "${CURL_TLS_ARGS[@]}" "${CURL_AUTH_ARGS[@]}" -H 'Content-Type: application/json' -X "$method" "${BASE_URL}${path}" -d "$data"
  else
    curl -sS "${CURL_TLS_ARGS[@]}" "${CURL_AUTH_ARGS[@]}" -H 'Content-Type: application/json' -X "$method" "${BASE_URL}${path}"
  fi
}

curl_simple() {
  local method="$1"
  local path="$2"
  curl -sS "${CURL_TLS_ARGS[@]}" "${CURL_AUTH_ARGS[@]}" -X "$method" "${BASE_URL}${path}"
}

# ---------- Sanity checks ----------
if ! [[ "$NUM_REPLICAS" =~ ^[0-9]+$ ]]; then
  echo "NUM_REPLICAS must be a non-negative integer. Got: ${NUM_REPLICAS}" >&2
  exit 1
fi

echo "Target: ${BASE_URL}"
echo "Template to create: ${TEMPLATE_NAME}_template (index_patterns: \"${TEMPLATE_NAME}*\")"
echo "number_of_replicas: ${NUM_REPLICAS}"
echo

# ---------- 1) Delete ALL indices ----------
echo "Deleting ALL indices..."
curl_simple DELETE "/%2A?expand_wildcards=all&pretty" || true
echo "Done deleting indices."
echo

# ---------- 2) Delete ALL templates ----------
echo "Deleting ALL templates (legacy, composable, component)..."
curl_simple DELETE "/_template/%2A?pretty" || true
curl_simple DELETE "/_index_template/%2A?pretty" || true
curl_simple DELETE "/_component_template/%2A?pretty" || true
echo "Done deleting templates."
echo

# ---------- 3) Create the requested composable index template ----------
echo "Creating template \"${TEMPLATE_NAME}_template\" with replicas=${NUM_REPLICAS} for \"${TEMPLATE_NAME}*\"..."

TEMPLATE_PAYLOAD=$(cat <<JSON
{
  "index_patterns": ["${TEMPLATE_NAME}*"],
  "template": {
    "settings": {
      "number_of_replicas": ${NUM_REPLICAS}
    }
  },
  "priority": 100
}
JSON
)

PUT_RESP=$(curl_json PUT "/_index_template/${TEMPLATE_NAME}_template?pretty" "$TEMPLATE_PAYLOAD" || true)
echo "$PUT_RESP"
echo

# ---------- Summary ----------
echo "All done."
echo "Indices wiped, templates wiped, and template \"${TEMPLATE_NAME}_template\" created."
echo "New indices matching \"${TEMPLATE_NAME}*\" will inherit number_of_replicas=${NUM_REPLICAS}."
