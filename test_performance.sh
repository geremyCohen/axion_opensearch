#!/bin/bash

set -euo pipefail

# Configuration
TARGET_HOST="10.0.0.122"
RESULTS_DIR="./results/optimization/c4a-64/4k/nyc_taxis"
CHECKPOINT_FILE="./test_progress.checkpoint"
LOG_FILE="./performance_test.log"

# Test parameters - 8 total runs (2 specific configs × 4 reps each)
CONFIGS=("60,16,16" "70,20,20")
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
        log "Starting fresh - no checkpoint found"
    fi
}

save_checkpoint() {
    cat > "$CHECKPOINT_FILE" << EOF
CURRENT_CLIENTS=$1
CURRENT_NODES=$2
CURRENT_SHARDS=$3
CURRENT_REP=$4
EOF
    log "Checkpoint saved: $1 $2 $3 $4"
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
    
    if ! nodesize=$nodes system_memory_percent=90 indices_breaker_total_limit=85% \
         indices_breaker_request_limit=70% indices_breaker_fielddata_limit=50% \
         num_of_shards=$shards ./install/dual_installer.sh update "$TARGET_HOST"; then
        error_exit "Failed to configure cluster with $nodes nodes, $shards shards"
    fi
    
    sleep 10  # Reduced wait time for testing
}

verify_cluster_active() {
    local max_attempts=5
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        if curl -s "http://$TARGET_HOST:9200/_cluster/health" | grep -q '"status":"green\|yellow"'; then
            log "Cluster is active"
            return 0
        fi
        log "Cluster not ready, attempt $attempt/$max_attempts"
        sleep 5
        ((attempt++))
    done
    
    error_exit "Cluster failed to become active after $max_attempts attempts"
}

run_benchmark() {
    local clients=$1
    local nodes=$2
    local shards=$3
    local rep=$4
    
    local test_name="${clients}_${nodes}-${shards}_${rep}"
    local osb_output="$RESULTS_DIR/${test_name}.json"
    
    log "Starting benchmark: $test_name"
    
    # Clear existing indices
    curl -s -X DELETE "http://$TARGET_HOST:9200/nyc_taxis*" > /dev/null || true
    sleep 2
    
    # Run OSB without timeout
    local osb_cmd="opensearch-benchmark run --workload=nyc_taxis \
        --target-hosts=$TARGET_HOST:9200,$TARGET_HOST:9201 \
        --client-options=use_ssl:false,verify_certs:false,timeout:60 \
        --kill-running-processes --include-tasks=index \
        --workload-params=bulk_indexing_clients:$clients,bulk_size:1000"
    
    log "Executing: $osb_cmd"
    
    if ! eval "$osb_cmd" > "$osb_output" 2>&1; then
        log "OSB execution failed for $test_name, checking output..."
        tail -10 "$osb_output" | while read line; do log "OSB: $line"; done
        error_exit "OSB execution failed for $test_name"
    fi
    
    # Check for success (more lenient for testing)
    if grep -q "SUCCESS\|Cumulative indexing time" "$osb_output"; then
        log "Benchmark completed successfully: $test_name"
    else
        log "Warning: Success marker not found, but continuing..."
    fi
}

main() {
    # Activate OpenSearch Benchmark environment
    source ~/opensearch-benchmark-workloads-env/bin/activate
    
    log "Starting OpenSearch performance test suite (TEST VERSION)"
    log "Test configurations: 2 client loads, 2 node/shard configs, 4 reps = 8 total runs"
    
    # Clear any existing checkpoint for fresh start
    rm -f "$CHECKPOINT_FILE"
    
    load_checkpoint
    
    local completed_runs=0
    
    for config in "${CONFIGS[@]}"; do
        IFS=',' read -r clients nodes shards <<< "$config"
        log "Processing configuration: $clients clients, $nodes nodes, $shards shards"
        
        # Configure cluster once per node/shard combination
        if ! configure_cluster "$nodes" "$shards"; then
            log "Skipping invalid configuration: $nodes nodes, $shards shards"
            continue
        fi
        verify_cluster_active
        
        for rep in $(seq 1 $REPETITIONS); do
            log "Processing repetition: $rep"
            
            run_benchmark "$clients" "$nodes" "$shards" "$rep"
            
            save_checkpoint "$clients" "$nodes" "$shards" "$rep"
            ((completed_runs++))
            
            log "Progress: $completed_runs/8 runs completed"
        done
    done
    
    rm -f "$CHECKPOINT_FILE"
    log "Test performance suite completed successfully"
}

main "$@"
