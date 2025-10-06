#!/bin/bash

set -euo pipefail

# Configuration
TARGET_HOST="$IP"

# Find existing run or create new timestamp
EXISTING_RUN=$(find ./results/optimization -name "test_progress.checkpoint" -type f 2>/dev/null | head -1)
if [[ -n "$EXISTING_RUN" ]]; then
    TIMESTAMP=$(basename $(dirname "$EXISTING_RUN"))
    echo "Found existing run: $TIMESTAMP"
else
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    echo "Starting new run: $TIMESTAMP"
fi

RESULTS_DIR="./results/optimization/$TIMESTAMP/c4a-64/4k/nyc_taxis"
CHECKPOINT_FILE="./results/optimization/$TIMESTAMP/test_progress.checkpoint"
LOG_FILE="./results/optimization/$TIMESTAMP/performance_test.log"

# Test parameters
CLIENT_LOADS=(60 70 80 90 100)
NODE_SHARD_CONFIGS=(16 20 24 28 32)  # nodes=shards for each value
REPETITIONS=4

# Initialize
mkdir -p "$RESULTS_DIR"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

log() {
    echo "[$(date -Iseconds)] $*" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR: $*"
    exit 1
}

load_checkpoint() {
    if [[ -f "$CHECKPOINT_FILE" ]]; then
        source "$CHECKPOINT_FILE"
        log "Checkpoint found: resuming from clients=$CURRENT_CLIENTS, nodes=$CURRENT_NODES, shards=$CURRENT_SHARDS, rep=$CURRENT_REP"
        
        # Clean up incomplete run files from the next run that would have been attempted
        local next_rep=$((CURRENT_REP + 1))
        local incomplete_run="${CURRENT_CLIENTS}_${CURRENT_NODES}-${CURRENT_SHARDS}_${next_rep}"
        if [[ -f "$RESULTS_DIR/${incomplete_run}.json" ]]; then
            log "Removing incomplete run file: ${incomplete_run}.json"
            rm -f "$RESULTS_DIR/${incomplete_run}.json"
            rm -f "$RESULTS_DIR/${incomplete_run}_summary.json"
            rm -f "$RESULTS_DIR/metrics_${incomplete_run}"*
        fi
    else
        CURRENT_CLIENTS=0
        CURRENT_NODES=0
        CURRENT_SHARDS=0
        CURRENT_REP=0
        log "No checkpoint found - starting fresh"
    fi
}

save_checkpoint() {
    cat > "$CHECKPOINT_FILE" << EOF
CURRENT_CLIENTS=$1
CURRENT_NODES=$2
CURRENT_SHARDS=$3
CURRENT_REP=$4
EOF
}

configure_cluster() {
    local nodes=$1
    local shards=$2
    
    # Validate shard count doesn't exceed node count
    if [[ $shards -gt $nodes ]]; then
        log "Skipping configuration: $shards shards > $nodes nodes (would cause unassigned shards)"
        return 1
    fi
    
    log "Configuring cluster: $nodes nodes, $shards shards"
    
    if ! nodesize=$nodes system_memory_percent=80 indices_breaker_total_limit=85% \
         indices_breaker_request_limit=70% indices_breaker_fielddata_limit=50% \
         num_of_shards=$shards ./install/dual_installer.sh update "$TARGET_HOST"; then
        error_exit "Failed to configure cluster with $nodes nodes, $shards shards"
    fi
    
    sleep 30  # Allow cluster to stabilize
}

verify_cluster_active() {
    local max_attempts=10
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        if curl -s "http://$TARGET_HOST:9200/_cluster/health" | grep -q '"status":"green\|yellow"'; then
            return 0
        fi
        log "Cluster not ready, attempt $attempt/$max_attempts"
        sleep 10
        ((attempt++))
    done
    
    error_exit "Cluster failed to become active after $max_attempts attempts"
}

collect_metrics() {
    local output_file=$1
    local sample_num=$2
    
    {
        echo "timestamp,$(date -Iseconds)"
        curl -s "http://$TARGET_HOST:9200/_nodes/stats/thread_pool,indices,os,process" | jq -c '.'
        curl -s "http://$TARGET_HOST:9200/_cluster/stats" | jq -c '.'
    } >> "${output_file}_${sample_num}"
}

run_benchmark() {
    set +e  # Disable exit on error for debugging
    local clients=$1
    local nodes=$2
    local shards=$3
    local rep=$4
    
    local test_name="${clients}_${nodes}-${shards}_${rep}"
    local osb_output="$RESULTS_DIR/${test_name}.json"
    local osb_log="$RESULTS_DIR/${test_name}.log"
    local metrics_file="$RESULTS_DIR/metrics_${test_name}"
    
    log "Starting benchmark: $test_name"
    
    # Clear existing indices
    log "Clearing indices..."
    curl -s -X DELETE "http://$TARGET_HOST:9200/nyc_taxis*" > /dev/null || true
    sleep 5
    
    # Run OSB
    log "Executing OSB for $test_name..."
    
    local osb_cmd="opensearch-benchmark run --workload=nyc_taxis \
        --target-hosts=$TARGET_HOST:9200,$TARGET_HOST:9201 \
        --client-options=use_ssl:false,verify_certs:false,timeout:60 \
        --kill-running-processes --include-tasks=index \
        --workload-params=bulk_indexing_clients:$clients,bulk_size:10000"
    
    log "About to execute OSB command..."
    if ! eval "$osb_cmd" > "$osb_log" 2>&1; then
        log "OSB execution failed for $test_name, checking output..."
        if [[ -f "$osb_log" ]]; then
            log "OSB output file exists, showing last 10 lines:"
            tail -10 "$osb_log" | while read line; do log "OSB: $line"; done
        else
            log "OSB output file does not exist"
        fi
        log "Continuing despite OSB failure..."
        set -e  # Re-enable exit on error
        return 1
    fi
    
    log "OSB execution completed for $test_name"
    
    # Extract test-run-id from OSB output
    local test_run_id=$(grep -o '\[Test Run ID\]: [a-f0-9-]*' "$osb_log" | cut -d' ' -f4)
    if [[ -n "$test_run_id" ]]; then
        log "Found test-run-id: $test_run_id"
        
        # Copy JSON results from OSB data directory
        local osb_json_file="$HOME/.benchmark/benchmarks/test-runs/$test_run_id/test_run.json"
        if [[ -f "$osb_json_file" ]]; then
            cp "$osb_json_file" "$osb_output"
            log "Copied OSB JSON results to $osb_output"
            
            # Create summary JSON
            if command -v jq >/dev/null 2>&1; then
                jq '{
                    test_run_id: ."test-run-id",
                    throughput: .results.op_metrics[0].throughput,
                    latency: .results.op_metrics[0].latency,
                    service_time: .results.op_metrics[0].service_time,
                    error_rate: (.results.op_metrics[0].error_rate // 0)
                }' "$osb_output" > "${osb_output%.json}_summary.json" 2>/dev/null || {
                    log "Warning: Failed to create summary JSON for $test_name"
                    echo '{"error": "Failed to parse results"}' > "${osb_output%.json}_summary.json"
                }
            fi
        else
            log "Warning: OSB JSON results file not found: $osb_json_file"
        fi
    else
        log "Warning: Could not extract test-run-id from OSB output"
    fi
    
    # Verify success
    if ! grep -q "SUCCESS\|✅ SUCCESS" "$osb_log"; then
        log "Warning: Success marker not found in $test_name output"
    fi
    
    log "Completed benchmark: $test_name"
    set -e  # Re-enable exit on error
}

main() {
    # Activate OpenSearch Benchmark environment
    log "Activating virtual environment..."
    source ~/opensearch-benchmark-workloads-env/bin/activate
    log "Virtual environment activated"
    
    # Test OSB command availability
    if command -v opensearch-benchmark >/dev/null 2>&1; then
        log "opensearch-benchmark command is available"
    else
        log "ERROR: opensearch-benchmark command not found after activation"
        exit 1
    fi
    
    log "Starting OpenSearch performance test suite"
    log "Total configurations: 25, Total runs: 100"
    
    load_checkpoint
    
    local total_runs=0
    local completed_runs=0
    
    for clients in "${CLIENT_LOADS[@]}"; do
        for node_shard in "${NODE_SHARD_CONFIGS[@]}"; do
            local nodes=$node_shard
            local shards=$node_shard
            
            # Skip if we haven't reached the checkpoint yet
            if [[ $clients -lt $CURRENT_CLIENTS ]] || \
               [[ $clients -eq $CURRENT_CLIENTS && $nodes -lt $CURRENT_NODES ]]; then
                continue
            fi
            
            # Configure cluster once per node/shard combination
            log "About to configure cluster: $nodes nodes, $shards shards"
            configure_cluster "$nodes" "$shards"
            log "Cluster configured, verifying..."
            verify_cluster_active
            log "Cluster verified, starting benchmark runs..."
            
            for rep in $(seq 1 $REPETITIONS); do
                log "Processing repetition $rep for $clients clients, $nodes nodes, $shards shards"
                log "Checkpoint values: CURRENT_CLIENTS=$CURRENT_CLIENTS, CURRENT_NODES=$CURRENT_NODES, CURRENT_SHARDS=$CURRENT_SHARDS, CURRENT_REP=$CURRENT_REP"
                
                # Skip if we haven't reached the checkpoint repetition yet
                if [[ $clients -eq $CURRENT_CLIENTS && $nodes -eq $CURRENT_NODES && $shards -eq $CURRENT_SHARDS && $rep -le $CURRENT_REP ]]; then
                    log "Skipping due to checkpoint: $clients,$nodes,$shards,$rep <= $CURRENT_CLIENTS,$CURRENT_NODES,$CURRENT_SHARDS,$CURRENT_REP"
                    completed_runs=$((completed_runs + 1))
                    continue
                fi
                
                log "Checkpoint check passed, proceeding with benchmark"
                log "About to increment total_runs (current value: $total_runs)"
                total_runs=$((total_runs + 1))
                log "total_runs incremented to: $total_runs"
                
                log "About to call run_benchmark function..."
                log "Function parameters: clients=$clients nodes=$nodes shards=$shards rep=$rep"
                
                if run_benchmark "$clients" "$nodes" "$shards" "$rep"; then
                    log "run_benchmark completed successfully"
                    save_checkpoint "$clients" "$nodes" "$shards" "$rep"
                else
                    log "run_benchmark failed, but continuing..."
                fi
                
                completed_runs=$((completed_runs + 1))
                
                log "Progress: $completed_runs/100 runs completed"
            done
        done
    done
    
    rm -f "$CHECKPOINT_FILE"
    log "Performance test suite completed successfully"
}

main "$@"
