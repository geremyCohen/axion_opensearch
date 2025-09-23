#!/usr/bin/env bash
set -euo pipefail

### --- Config --- ###
OPENSEARCH_BIN="/opt/opensearch/bin/opensearch"
HOST="10.0.0.52"
PORT="9200"
WORKLOAD="nyc_taxis"
BENCHMARK_BIN="$HOME/benchmark-env/bin/opensearch-benchmark"
CLIENT_OPTIONS="use_ssl:false,verify_certs:false"

# Optional: authentication
CURL_AUTH=()
if [[ -n "${OPENSEARCH_USER:-}" && -n "${OPENSEARCH_PASS:-}" ]]; then
  CURL_AUTH=(-u "${OPENSEARCH_USER}:${OPENSEARCH_PASS}")
fi

### --- Helpers --- ###
start_opensearch() {
  echo "[INFO] Starting OpenSearch..."
  nohup "$OPENSEARCH_BIN" > opensearch.log 2>&1 &
  export OPENSEARCH_PID=$!
  echo "[INFO] OpenSearch PID: $OPENSEARCH_PID"
}

stop_opensearch() {
  echo "[INFO] Stopping OpenSearch..."
  pkill -f "$OPENSEARCH_BIN" || true
  sleep 5
}

wait_for_cluster() {
  echo "[INFO] Waiting for cluster to start..."
  for i in {1..120}; do
    if curl -fsS "${CURL_AUTH[@]}" "http://${HOST}:${PORT}" >/dev/null 2>&1; then
      status=$(curl -s "${CURL_AUTH[@]}" "http://${HOST}:${PORT}/_cluster/health" | jq -r '.status // empty')
      if [[ "$status" == "green" || "$status" == "yellow" ]]; then
        echo "[INFO] Cluster is up (status=$status)"
        return 0
      fi
    fi
    sleep 2
    echo -n "."
  done
  echo "[ERROR] Cluster did not start in time."
  exit 1
}

verify_counters_zero() {
  echo "[INFO] Checking node indices counters..."
  stats=$(curl -s "${CURL_AUTH[@]}" "http://${HOST}:${PORT}/_nodes/stats/indices" | jq '
    .nodes[] | {
      merges_total_time: .indices.merges.total_time_in_millis,
      indexing_total_time: .indices.indexing.index_time_in_millis,
      refresh_total_time: .indices.refresh.total_time_in_millis,
      flush_total_time: .indices.flush.total_time_in_millis
    }')
  echo "$stats"
}

run_benchmark() {
  echo "[INFO] Running benchmark workload=${WORKLOAD}..."
  "$BENCHMARK_BIN" execute-test \
    --workload="$WORKLOAD" \
    --target-hosts="${HOST}:${PORT}" \
    --client-options="$CLIENT_OPTIONS"
}

### --- Main --- ###
stop_opensearch
start_opensearch
wait_for_cluster
verify_counters_zero

