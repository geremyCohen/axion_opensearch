#!/usr/bin/env bash
#
# tune_bulk_clients.sh  (v2)
# Sweep bulk_indexing_clients for OpenSearch Benchmark ingest and recommend a client count.
# Adds: --single to run just one trial, --verbose to echo commands and show OSB output clearly,
#       and extra sanity prints (docs count after run).
#
# Usage (sweep):
#   ./tune_bulk_clients.sh \
#     --host http://10.0.0.59:9200 \
#     --workload-path ./osb_local_workloads/nyc_taxis_clean \
#     --counts 8,12,16,20,24,32,40,48 \
#     --bulk-size 10000 \
#     --warmup-iter 10 \
#     --mpstat true \
#     --threshold 0.97
#
# Usage (single run for smoke test at clients=24):
#   ./tune_bulk_clients.sh --host http://10.0.0.59:9200 \
#     --workload-path ./osb_local_workloads/nyc_taxis_clean \
#     --counts 24 --single true --verbose true
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
SINGLE="false"
VERBOSE="false"
SINGLE_SECONDS="60"
# derive SSH_HOST from HOST (strip scheme and port)
_RAW_HOST="${HOST#http://}"
_RAW_HOST="${_RAW_HOST#https://}"
SSH_HOST="${_RAW_HOST%%:*}"

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
    --single) SINGLE="$2"; shift 2;;
    --single-seconds) SINGLE_SECONDS="$2"; shift 2;;
    --verbose) VERBOSE="$2"; shift 2;;
    --ssh-host) SSH_HOST="$2"; shift 2;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

# re-derive SSH_HOST from HOST unless explicitly overridden via --ssh-host
if [[ -z "${SSH_HOST:-}" || "$SSH_HOST" == "${HOST#http://}" ]]; then
  _RAW_HOST="${HOST#http://}"
  _RAW_HOST="${_RAW_HOST#https://}"
  SSH_HOST="${_RAW_HOST%%:*}"
fi

[[ "$VERBOSE" == "true" ]] && set -x

# Require deps
command -v jq >/dev/null || { echo "jq is required"; exit 1; }
command -v opensearch-benchmark >/dev/null || { echo "opensearch-benchmark not found in PATH"; exit 1; }

# Prepare CSV
echo "arch,clients,docs_per_s,p50_ms,p99_ms,cpu_user_pct,cpu_sys_pct,cpu_iowait_pct,rejections_write,rejections_bulk,docs_after_run" > "$RESULTS_CSV"

IFS=, read -r -a CLIENTS_ARR <<< "$COUNTS"
if [[ "$SINGLE" == "true" ]]; then
  # Just use the first element of CLIENTS_ARR
  CLIENTS_ARR=("${CLIENTS_ARR[0]}")
fi

get_arch() {
  curl -s "$HOST/_nodes" | jq -r '.nodes[]?.os.arch' | head -1
}

avg_from_mpstat() {
  local file="$1"
  awk '/all/ {usr+=$3; sys+=$5; wai+=$6; n++} END{ if(n==0){print "NA,NA,NA"} else {printf "%.1f,%.1f,%.1f\n", usr/n, sys/n, wai/n}}' "$file"
}

docs_count() {
  curl -s "$HOST/nyc_taxis/_count" | jq -r '.count // 0' 2>/dev/null
}

for C in "${CLIENTS_ARR[@]}"; do
  echo "=== clients=$C ===" >&2

  # Clean/create index (no mid-run changes)
  echo "[prep] reset nyc_taxis index" >&2
  curl -s -X DELETE "$HOST/nyc_taxis" >/dev/null || true
  curl -s -X PUT "$HOST/nyc_taxis" -H 'Content-Type: application/json' -d '{"settings":{}}' >/dev/null

  # Start mpstat sampler if enabled
  MPFILE="$(mktemp)"
  if [[ "$MPSTAT" == "true" ]]; then
    # run mpstat on the remote host via SSH; install sysstat if missing
    if ! ssh -o BatchMode=yes "$SSH_HOST" "command -v mpstat >/dev/null"; then
      echo "[warn] mpstat not found on remote; attempting to install sysstat" >&2
      ssh "$SSH_HOST" "sudo apt-get update && sudo apt-get install -y sysstat" >/dev/null 2>&1 || true
    fi
    if ssh -o BatchMode=yes "$SSH_HOST" "command -v mpstat >/dev/null"; then
      if [[ "$SINGLE" == "true" ]]; then
        ssh "$SSH_HOST" "mpstat 1 $SINGLE_SECONDS" > "$MPFILE" 2>/dev/null &
      else
        ssh "$SSH_HOST" "mpstat 1" > "$MPFILE" 2>/dev/null &
      fi
      MPPID=$!
    else
      echo "[warn] mpstat unavailable on remote; CPU sampling disabled" >&2
      MPSTAT="false"
    fi
  fi

  # Build OSB command
  OSB_CMD=(opensearch-benchmark run
    --workload-path="$WORKLOAD_PATH"
    --target-hosts="${HOST#http://}"
    --client-options=use_ssl:false,verify_certs:false,timeout:60
    --kill-running-processes
    --include-tasks="index"
    --workload-params="index_warmup_time_period:5,update_warmup_time_period:5,warmup_iterations:${WARMUP_ITER},bulk_indexing_clients:${C},bulk_size:${BULK_SIZE}"
  )

  echo "[cmd] ${OSB_CMD[*]}" >&2

  START_TS=$(date +%s)
  BASE_DOCS=$(docs_count)

  # Run OSB ingest-only and keep full output (stdout+stderr)
  if [[ "$SINGLE" == "true" ]]; then
    echo "[single] running with timeout ${SINGLE_SECONDS}s" >&2
    OUT="$(timeout -s INT ${SINGLE_SECONDS}s "${OSB_CMD[@]}" 2>&1 | tee /dev/stderr)" || true
  else
    OUT="$("${OSB_CMD[@]}" 2>&1 | tee /dev/stderr)" || true
  fi

  END_TS=$(date +%s)
  DURATION=$(( END_TS - START_TS ))
  [[ $DURATION -le 0 ]] && DURATION=1

  # Stop mpstat
  if [[ "$MPSTAT" == "true" && -n "${MPPID:-}" ]]; then
    kill "$MPPID" >/dev/null 2>&1 || true
    sleep 0.2
  fi

  # Parse OSB output for docs/s and latency percentiles if present
  # Try multiple patterns
  DOCS=$(echo "$OUT" | awk '/docs\/s|Throughput|Indexing throughput/ {last=$0} END{print last}' | awk '{print $NF}')
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

  # Docs in index after run (sanity)
  DOCS_AFTER="$(docs_count)"
  DELTA_DOCS=$(( DOCS_AFTER - BASE_DOCS ))
  if [[ -z "$DOCS" || "$DOCS" == "0" || "$DOCS" == "0.0" ]]; then
    DOCS=$(awk -v d="$DELTA_DOCS" -v s="$DURATION" 'BEGIN { if (s<=0) s=1; printf "%.2f", d/s }')
    echo "[post] using estimated docs/s from _count delta: $DOCS (delta=$DELTA_DOCS over ${DURATION}s)" >&2
  fi
  echo "[post] docs_after_run=$DOCS_AFTER  (docs/s=$DOCS over ${DURATION}s)" >&2

  ARCH="$(curl -s "$HOST/_nodes" | jq -r '.nodes[]?.os.arch' | head -1)"
  echo "$ARCH,$C,$DOCS,$P50,$P99,$CPU_USER,$CPU_SYS,$CPU_WAIT,$RJ_WRITE,$RJ_BULK,$DOCS_AFTER" | tee -a "$RESULTS_CSV" >/dev/null
done

# If SINGLE mode, skip recommendation and just show CSV path
if [[ "$SINGLE" == "true" ]]; then
  echo "Single run complete."
  echo "CSV written to: $RESULTS_CSV"
  exit 0
fi

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
            row['docs_after_run'] = int(float(row.get('docs_after_run','0')))
        except:
            continue
        # normalize fields
        for k in ('cpu_iowait_pct', 'rejections_write', 'rejections_bulk'):
            row[k] = 0.0 if row[k] in ('NA','') else float(row[k])
        rows.append(row)

if not rows:
    print("No data collected.", file=sys.stderr); sys.exit(1)

# filter out runs that didn't ingest any docs
rows = [r for r in rows if r['docs_after_run'] > 0]

if not rows:
    print("No successful ingest detected (docs_after_run==0 for all trials).", file=sys.stderr); sys.exit(2)

peak = max(rows, key=lambda x: x['docs_per_s'])['docs_per_s']
target = peak * thresh

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
    best = max(rows, key=lambda x: x['docs_per_s'])
    print("RECOMMENDATION (peak only; quality gates failed)")
    print(f"  peak_docs_per_s: {peak:.2f}")
    print(f"  chosen_clients: {best['clients']}  docs/s={best['docs_per_s']:.2f}  iowait={best['cpu_iowait_pct']:.1f}%  rej(write/bulk)={int(best['rejections_write'])}/{int(best['rejections_bulk'])}")
PYCODE

echo ""
echo "CSV written to: $RESULTS_CSV"
