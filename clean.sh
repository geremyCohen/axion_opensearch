#!/usr/bin/env bash
set -euo pipefail

### --- Config --- ###
SERVICE_NAME="opensearch"                  # systemd service name
HOST="10.0.0.52"
PORT="9200"
WORKLOAD="nyc_taxis"
BENCHMARK_BIN="$HOME/benchmark-env/bin/opensearch-benchmark"
CLIENT_OPTIONS="use_ssl:false,verify_certs:false"

# If your cluster has security/basic auth enabled, set these env vars before running:
# export OPENSEARCH_USER="admin"
# export OPENSEARCH_PASS="admin-password"
CURL_AUTH=()
if [[ -n "${OPENSEARCH_USER:-}" && -n "${OPENSEARCH_PASS:-}" ]]; then
  CURL_AUTH=(-u "${OPENSEARCH_USER}:${OPENSEARCH_PASS}")
fi

# Set to 1 to make non-zero counters a hard error (script exits).
REQUIRE_ZERO="${REQUIRE_ZERO:-0}"

### --- Helpers --- ###
curl_json() {
  curl -sS "${CURL_AUTH[@]}" "http://${HOST}:${PORT}$1"
}

wait_for_port() {
  echo "[INFO] Waiting for http://${HOST}:${PORT} ..."
  for i in {1..120}; do
    if curl -fsS "${CURL_AUTH[@]}" "http://${HOST}:${PORT}" >/dev/null 2>&1; then
      echo "[INFO] Port is up."
      return 0
    fi
    sleep 1
  done
  echo "[ERROR] Timed out waiting for port ${PORT}."
  return 1
}

wait_for_cluster_health() {
  echo "[INFO] Waiting for cluster health (yellow/green)..."
  for i in {1..120}; do
    status=$(curl_json "/_cluster/health" | jq -r '.status // empty' || true)
    if [[ "$status" == "yellow" || "$status" == "green" ]]; then
      echo "[INFO] Cluster health: $status"
      return 0
    fi
    sleep 1
  done
  echo "[ERROR] Timed out waiting for cluster health."
  return 1
}

verify_counters_zero() {
  echo "[INFO] Checking node indices counters..."
  stats=$(curl_json "/_nodes/stats/indices" | jq '
    .nodes[] | {
      merges_total_time: .indices.merges.total_time_in_millis,
      indexing_total_time: .indices.indexing.index_time_in_millis,
      refresh_total_time: .indices.refresh.total_time_in_millis,
      flush_total_time: .indices.flush.total_time_in_millis
    }')
  echo "$stats"

  # If any value contains a non-zero digit, it's not zero.
  if echo "$stats" | grep -qE ':[[:space:]]*[1-9]'; then
    if [[ "$REQUIRE_ZERO" == "1" ]]; then
      echo "[ERROR] Counters are not zero. Aborting because REQUIRE_ZERO=1."
      exit 2
    else
      echo "[WARNING] Counters are not zero. Proceeding."
    fi
  else
    echo "[INFO] All counters are zero ✅"
  fi
}

run_benchmark() {
  echo "[INFO] Running benchmark: workload=${WORKLOAD}"
  "$BENCHMARK_BIN" execute-test \
    --workload="$WORKLOAD" \
    --target-hosts="${HOST}:${PORT}" \
    --client-options="$CLIENT_OPTIONS"
}

### --- Main --- ###
echo "[INFO] Restarting OpenSearch (systemd: ${SERVICE_NAME})..."
sudo systemctl restart "${SERVICE_NAME}"

wait_for_port
wait_for_cluster_health
verify_counters_zero
run_benchmark

