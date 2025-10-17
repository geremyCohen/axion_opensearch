#!/usr/bin/env bash
#
# tune_bulk_clients.sh
# Sweep bulk_indexing_clients for OpenSearch Benchmark ingest and recommend a client count.
#
# Usage:
#   ./tune_bulk_clients.sh \
#     --host http://10.0.0.59:9200 \
#     --workload-path ./osb_local_workloads/nyc_taxis_clean \
#     --counts 8,12,16,20,24,32,40,48 \
#     --bulk-size 10000 \
#     --warmup-iter 10 \
#     --mpstat true \
#     --threshold 0.97
#
# Notes:
# - Assumes nyc_taxis index template already enforces 6 shards, 0 replicas, refresh=30s.
# - No mid-run cluster changes are made; per-trial index is created before the run.
# - Produces tune_results.csv and a summary recommendation at the end.
#
set -euo pipefail

# Defaults
HOST="http://127.0.0.1:9200"
WORKLOAD_PATH="./osb_local_workloads/nyc_taxis_clean"
COUNTS="8,12,16,20,24,32,40,48"
BULK_SIZE="10000"
WARMUP_ITER="10"
MPSTAT="true"
THRESHOLD="0.97"   # choose minimal clients achieving >= 97% of peak throughput
CPU_MAX_WAIT="10.0" # quality gate: avg iowait <= 10%
RESULTS_CSV="tune_results.csv"

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2;;
    --workload-path) WORKLOAD_PATH="$2"; shift 2;;
    --counts) COUNTS="$2"; shift 2;;
    --bulk-size) BULK_SIZE="$2"; shift 2;;
    --warmup-iter) WARMUP_ITER="$2"; shift 2;;
    --mpstat) MPSTAT="$2"; shift 2;;
    --threshold) THRESHOLD="$2"; shift 2;;
    --cpu-max-wait) CPU_MAX_WAIT="$2"; shift 2;;
    --out) RESULTS_CSV="$2"; shift 2;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

# Require deps
command -v jq >/dev/null || { echo "jq is required"; exit 1; }
command -v opensearch-benchmark >/dev/null || { echo "opensearch-benchmark not found in PATH"; exit 1; }

# Prepare CSV
echo "arch,clients,docs_per_s,p50_ms,p99_ms,cpu_user_pct,cpu_sys_pct,cpu_iowait_pct,rejections_write,rejections_bulk" > "$RESULTS_CSV"

IFS=, read -r -a CLIENTS_ARR <<< "$COUNTS"

get_arch() {
  curl -s "$HOST/_nodes" | jq -r '.nodes[]?.os.arch' | head -1
}

avg_from_mpstat() {
  local file="$1"
  # mpstat output has a header every interval; average over lines with "all"
  # Field positions: %usr at $3, %sys at $5, %iowait at $6
  awk '/all/ {usr+=$3; sys+=$5; wai+=$6; n++} END{ if(n==0){print "NA,NA,NA"} else {printf "%.1f,%.1f,%.1f\n", usr/n, sys/n, wai/n}}' "$file"
}

for C in "${CLIENTS_ARR[@]}"; do
  echo "=== clients=$C ===" >&2

  # Clean/create index (no mid-run changes)
  curl -s -X DELETE "$HOST/nyc_taxis" >/dev/null || true
  curl -s -X PUT "$HOST/nyc_taxis" -H 'Content-Type: application/json' -d '{"settings":{}}' >/dev/null

  # Start mpstat sampler if enabled
  MPFILE="$(mktemp)"
  if [[ "$MPSTAT" == "true" ]]; then
    if ! command -v mpstat >/dev/null; then
      echo "mpstat not found; install sysstat for CPU sampling (continuing without CPU stats)" >&2
      MPSTAT="false"
    fi
    if [[ "$MPSTAT" == "true" ]]; then
      (mpstat 1 > "$MPFILE") &
      MPPID=$!
    fi
  fi

  # Run OSB ingest-only
  # Capture stdout to parse docs/s and (if present) latency percentiles
  OUT="$(opensearch-benchmark run \
    --workload-path="$WORKLOAD_PATH" \
    --target-hosts="${HOST#http://}" \
    --client-options=use_ssl:false,verify_certs:false,timeout:60 \
    --kill-running-processes \
    --include-tasks="index" \
    --workload-params="index_warmup_time_period:5,update_warmup_time_period:5,warmup_iterations:10,bulk_indexing_clients:${C},bulk_size:${BULK_SIZE}" \
    2>&1 | tee /dev/stderr)" || true

  # Stop mpstat
  if [[ "${MPSTAT}" == "true" && -n "${MPPID:-}" ]]; then
    kill "$MPPID" >/dev/null 2>&1 || true
    sleep 0.2
  fi

  # Parse OSB output for docs/s and p50/p99 if present
  # Try common patterns; fall back gracefully.
  DOCS=$(echo "$OUT" | awk '/docs\/s|Throughput/ {v=$NF} END{print v}')
  [[ -z "$DOCS" ]] && DOCS=0

  P50=$(echo "$OUT" | awk '/p50|50.0 percentile/ {v=$NF} END{print v}')
  P99=$(echo "$OUT" | awk '/p99|99.0 percentile/ {v=$NF} END{print v}')
  [[ -z "$P50" ]] && P50="NA"
  [[ -z "$P99" ]] && P99="NA"

  # Threadpool rejections after run
  STATS="$(curl -s "$HOST/_nodes/stats/thread_pool?filter_path=nodes.*.thread_pool.write.rejected,nodes.*.thread_pool.bulk.rejected")"
  RJ_WRITE=$(echo "$STATS" | jq '.[].thread_pool.write.rejected? // 0' 2>/dev/null | paste -sd+ - | bc 2>/dev/null || echo 0)
  RJ_BULK=$( echo "$STATS" | jq '.[].thread_pool.bulk.rejected? // 0'  2>/dev/null | paste -sd+ - | bc 2>/dev/null || echo 0)

  # CPU averages
  if [[ -s "$MPFILE" ]]; then
    IFS=, read -r CPU_USER CPU_SYS CPU_WAIT <<< "$(avg_from_mpstat "$MPFILE")"
  else
    CPU_USER="NA"; CPU_SYS="NA"; CPU_WAIT="NA"
  fi
  rm -f "$MPFILE"

  ARCH="$(get_arch)"
  echo "$ARCH,$C,$DOCS,$P50,$P99,$CPU_USER,$CPU_SYS,$CPU_WAIT,$RJ_WRITE,$RJ_BULK" | tee -a "$RESULTS_CSV" >/dev/null
done

# Compute recommendation
python3 - "$RESULTS_CSV" "$THRESHOLD" "$CPU_MAX_WAIT" <<'PYCODE'
import csv, sys

csv_path, thresh, max_wait = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
rows = []
with open(csv_path) as f:
    r = csv.DictReader(f)
    for row in r:
        try:
            row['clients'] = int(row['clients'])
            row['docs_per_s'] = float(row['docs_per_s'])
        except:
            continue
        # normalize fields
        for k in ('cpu_iowait_pct', 'rejections_write', 'rejections_bulk'):
            row[k] = 0.0 if row[k] in ('NA','') else float(row[k])
        rows.append(row)

if not rows:
    print("No data collected.", file=sys.stderr); sys.exit(1)

peak = max(rows, key=lambda x: x['docs_per_s'])['docs_per_s']
target = peak * thresh

# Quality gates: no rejections, iowait <= max_wait (if present)
def ok(q):
    if q['rejections_write'] > 0 or q['rejections_bulk'] > 0:
        return False
    if isinstance(q['cpu_iowait_pct'], float) and q['cpu_iowait_pct'] > max_wait:
        return False
    return True

candidates = sorted([q for q in rows if q['docs_per_s'] >= target and ok(q)], key=lambda x: x['clients'])

if candidates:
    rec = candidates[0]
    print("RECOMMENDATION")
    print(f"  peak_docs_per_s: {peak:.2f}")
    print(f"  threshold: {thresh*100:.0f}% -> target_docs_per_s >= {target:.2f}")
    print(f"  chosen_clients: {rec['clients']}  docs/s={rec['docs_per_s']:.2f}  iowait={rec['cpu_iowait_pct']:.1f}%  rej(write/bulk)={int(rec['rejections_write'])}/{int(rec['rejections_bulk'])}")
else:
    # fallback: choose clients at peak even if quality gates failed
    best = max(rows, key=lambda x: x['docs_per_s'])
    print("RECOMMENDATION (peak only; quality gates failed)")
    print(f"  peak_docs_per_s: {peak:.2f}")
    print(f"  chosen_clients: {best['clients']}  docs/s={best['docs_per_s']:.2f}  iowait={best['cpu_iowait_pct']:.1f}%  rej(write/bulk)={int(best['rejections_write'])}/{int(best['rejections_bulk'])}")
PYCODE

echo ""
echo "CSV written to: $RESULTS_CSV"
