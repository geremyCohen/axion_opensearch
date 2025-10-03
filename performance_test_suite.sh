#!/bin/bash

set -euo pipefail

# Configuration
TARGET_HOST="10.0.0.122"
RESULTS_DIR="./results/optimization/c4a-64/4k/nyc_taxis"
CHECKPOINT_FILE="./test_progress.checkpoint"
LOG_FILE="./performance_test.log"

# Test parameters
CLIENT_LOADS=(60 70 80 90 100)
NODE_CONFIGS=(16 20 24 28 32)
SHARD_CONFIGS=(16 20 24 28 32)
REPETITIONS=4

# Initialize
mkdir -p "$RESULTS_DIR"
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
        log "Resuming from checkpoint: clients=$CURRENT_CLIENTS, nodes=$CURRENT_NODES, shards=$CURRENT_SHARDS, rep=$CURRENT_REP"
    else
        CURRENT_CLIENTS=0
        CURRENT_NODES=0
        CURRENT_SHARDS=0
        CURRENT_REP=0
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

force_compaction() {
    log "Forcing index compaction"
    curl -s -X POST "http://$TARGET_HOST:9200/nyc_taxis/_forcemerge?max_num_segments=1" > /dev/null || true
}

run_benchmark() {
    local clients=$1
    local nodes=$2
    local shards=$3
    local rep=$4
    
    local test_name="${clients}_${nodes}-${shards}_${rep}"
    local osb_output="$RESULTS_DIR/${test_name}.json"
    local metrics_file="$RESULTS_DIR/metrics_${test_name}"
    
    log "Starting benchmark: $test_name"
    
    # Clear existing indices
    curl -s -X DELETE "http://$TARGET_HOST:9200/nyc_taxis*" > /dev/null || true
    sleep 5
    
    # Start metrics collection in background
    local metrics_pid
    (
        local sample=1
        while kill -0 $$ 2>/dev/null; do
            collect_metrics "$metrics_file" "$sample"
            ((sample++))
            sleep 60
        done
    ) &
    metrics_pid=$!
    
    # Force compaction before test
    force_compaction
    
    # Run OSB
    local osb_cmd="~/benchmark-env/bin/opensearch-benchmark execute-test --workload=nyc_taxis \
        --target-hosts=$TARGET_HOST:9200,$TARGET_HOST:9201 \
        --client-options=use_ssl:false,verify_certs:false,timeout:60 \
        --kill-running-processes --include-tasks=index \
        --workload-params=bulk_indexing_clients:$clients,bulk_size:10000"
    
    if ! timeout 7200 bash -c "$osb_cmd" > "$osb_output" 2>&1; then
        kill $metrics_pid 2>/dev/null || true
        error_exit "OSB execution failed for $test_name"
    fi
    
    # Stop metrics collection
    kill $metrics_pid 2>/dev/null || true
    
    # Verify success
    if ! grep -q "\[INFO\] ✅ SUCCESS" "$osb_output"; then
        error_exit "OSB did not complete successfully for $test_name"
    fi
    
    # Force compaction after test
    force_compaction
    
    # Parse and save summary
    jq '{
        throughput: .["service-time"] // 0,
        latency: .["latency-percentiles"] // {},
        indexing_rate: .["indexing-rate"] // 0,
        errors: .["error-count"] // 0
    }' "$osb_output" > "${osb_output%.json}_summary.json" 2>/dev/null || true
    
    log "Completed benchmark: $test_name"
}

main() {
    log "Starting OpenSearch performance test suite"
    log "Total configurations: 125, Total runs: 500"
    
    load_checkpoint
    
    local total_runs=0
    local completed_runs=0
    
    for clients in "${CLIENT_LOADS[@]}"; do
        [[ $clients -lt $CURRENT_CLIENTS ]] && continue
        
        for nodes in "${NODE_CONFIGS[@]}"; do
            [[ $clients -eq $CURRENT_CLIENTS && $nodes -lt $CURRENT_NODES ]] && continue
            
            for shards in "${SHARD_CONFIGS[@]}"; do
                [[ $clients -eq $CURRENT_CLIENTS && $nodes -eq $CURRENT_NODES && $shards -lt $CURRENT_SHARDS ]] && continue
                
                # Configure cluster once per node/shard combination
                if ! configure_cluster "$nodes" "$shards"; then
                    log "Skipping invalid configuration: $nodes nodes, $shards shards"
                    continue
                fi
                verify_cluster_active
                
                for rep in $(seq 1 $REPETITIONS); do
                    [[ $clients -eq $CURRENT_CLIENTS && $nodes -eq $CURRENT_NODES && $shards -eq $CURRENT_SHARDS && $rep -le $CURRENT_REP ]] && { ((completed_runs++)); continue; }
                    
                    ((total_runs++))
                    
                    run_benchmark "$clients" "$nodes" "$shards" "$rep"
                    
                    save_checkpoint "$clients" "$nodes" "$shards" "$rep"
                    ((completed_runs++))
                    
                    log "Progress: $completed_runs/500 runs completed"
                done
            done
        done
    done
    
    rm -f "$CHECKPOINT_FILE"
    log "Performance test suite completed successfully"
}

main "$@"
