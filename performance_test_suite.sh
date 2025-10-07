#!/bin/bash

set -euo pipefail

# Configuration
TARGET_HOST="$IP"

# Find existing run or create new timestamp
if [[ -d "./results/optimization" ]]; then
    EXISTING_RUN=$(find ./results/optimization -name "test_progress.checkpoint" -type f 2>/dev/null | head -1)
else
    EXISTING_RUN=""
fi

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
#REPETITIONS=4

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
        
        # Validate that the checkpoint configuration is reasonable
        if [[ $CURRENT_NODES -gt 16 ]]; then
            log "WARNING: Checkpoint references $CURRENT_NODES nodes, but max supported is 16. Resetting checkpoint."
            rm -f "$CHECKPOINT_FILE"
            CURRENT_CLIENTS=0
            CURRENT_NODES=0
            CURRENT_SHARDS=0
            CURRENT_REP=0
            return
        fi
        
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

safe_delete_indices() {
    log "Performing safe index cleanup..."
    
    # Delete all indices (not just nyc_taxis*)
    curl -s -X DELETE "http://$TARGET_HOST:9200/*" > /dev/null 2>&1 || true
    curl -s -X DELETE "http://$TARGET_HOST:9200/nyc_taxis*" > /dev/null 2>&1 || true
    
    # Wait for deletion to complete
    local attempts=0
    while [[ $attempts -lt 10 ]]; do
        local indices=$(curl -s "http://$TARGET_HOST:9200/_cat/indices/nyc_taxis*" 2>/dev/null | wc -l)
        if [[ $indices -eq 0 ]]; then
            log "Index cleanup completed"
            return 0
        fi
        log "Waiting for index deletion... (attempt $((attempts+1))/10)"
        sleep 3
        ((attempts++))
    done
    
    log "WARNING: Index cleanup may be incomplete"
}

detect_cluster_issues() {
    local health_response=$(curl -s --connect-timeout 10 "http://$TARGET_HOST:9200/_cluster/health" 2>/dev/null)
    
    if [[ -z "$health_response" ]]; then
        log "ERROR: Cluster not responding"
        return 1
    fi
    
    local status=$(echo "$health_response" | jq -r '.status // "unknown"' 2>/dev/null)
    local unassigned=$(echo "$health_response" | jq -r '.unassigned_shards // 0' 2>/dev/null)
    
    log "Cluster status: $status, unassigned shards: $unassigned"
    
    if [[ "$status" == "red" && $unassigned -gt 0 ]]; then
        log "DETECTED: Red cluster with unassigned shards - attempting recovery"
        return 1
    fi
    
    return 0
}

recover_cluster() {
    log "Attempting cluster recovery..."
    
    # Force delete all indices to clear unassigned shards
    safe_delete_indices
    
    # Wait for cluster to stabilize
    sleep 10
    
    # Check if recovery worked
    if detect_cluster_issues; then
        log "Cluster recovery successful"
        return 0
    else
        log "Cluster recovery failed"
        return 1
    fi
}

wait_for_green_cluster() {
    local max_attempts=15
    local attempt=1
    
    log "Waiting for cluster to become green/yellow..."
    
    while [[ $attempt -le $max_attempts ]]; do
        local health_response=$(curl -s --connect-timeout 10 "http://$TARGET_HOST:9200/_cluster/health" 2>/dev/null)
        
        if [[ -n "$health_response" ]]; then
            local status=$(echo "$health_response" | jq -r '.status // "unknown"' 2>/dev/null)
            local nodes=$(echo "$health_response" | jq -r '.number_of_nodes // 0' 2>/dev/null)
            local unassigned=$(echo "$health_response" | jq -r '.unassigned_shards // 0' 2>/dev/null)
            
            log "Cluster check: status=$status, nodes=$nodes, unassigned=$unassigned (attempt $attempt/$max_attempts)"
            
            if [[ "$status" == "green" || "$status" == "yellow" ]] && [[ $unassigned -eq 0 ]]; then
                log "Cluster is healthy"
                return 0
            fi
            
            if [[ "$status" == "red" ]]; then
                log "Red cluster detected - attempting recovery"
                if recover_cluster; then
                    continue  # Retry the health check
                fi
            fi
        fi
        
        sleep 10
        ((attempt++))
    done
    
    log "WARNING: Cluster not fully healthy after $max_attempts attempts"
    return 1
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
    
    # Pre-scaling validation and cleanup
    log "Pre-scaling validation..."
    if ! detect_cluster_issues; then
        log "Cluster issues detected - attempting recovery before scaling"
        if ! recover_cluster; then
            log "ERROR: Cannot recover cluster before scaling"
            return 1
        fi
    fi
    
    # Safe index cleanup before scaling
    safe_delete_indices
    
    # Wait for cluster to be healthy before scaling
    if ! wait_for_green_cluster; then
        log "WARNING: Cluster not green before scaling, but continuing..."
    fi
    
    log "Attempting cluster configuration update..."
    if nodesize=$nodes system_memory_percent=80 indices_breaker_total_limit=85% \
         indices_breaker_request_limit=70% indices_breaker_fielddata_limit=50% \
         num_of_shards=$shards ./install/dual_installer.sh update "$TARGET_HOST" 2>&1 | tee -a "$LOG_FILE"; then
        log "Cluster configuration completed"
    else
        log "WARNING: Cluster configuration may have failed"
        return 1
    fi
    
    # Post-scaling validation
    sleep 30
    log "Post-scaling validation..."
    
    if ! wait_for_green_cluster; then
        log "ERROR: Cluster unhealthy after scaling"
        if ! recover_cluster; then
            log "ERROR: Failed to recover cluster after scaling"
            return 1
        fi
    fi
    
    log "Cluster scaling completed successfully"
}

verify_cluster_active() {
    log "Verifying cluster is ready for benchmarking..."
    
    # Use the comprehensive health check
    if wait_for_green_cluster; then
        log "Cluster verification successful"
        return 0
    else
        log "WARNING: Cluster verification failed, but continuing with benchmark attempt"
        return 0  # Don't fail - let the benchmark attempt proceed
    fi
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
    
    # Safe index cleanup before benchmark
    log "Performing safe index cleanup before benchmark..."
    safe_delete_indices
    
    # Verify cluster is healthy before benchmark
    if ! detect_cluster_issues; then
        log "Cluster issues detected before benchmark - attempting recovery"
        if ! recover_cluster; then
            log "ERROR: Cannot recover cluster before benchmark"
            set -e
            return 1
        fi
    fi
    
    # Run OSB
    log "Executing OSB for $test_name..."
    
    local osb_cmd="opensearch-benchmark run --workload=nyc_taxis \
        --target-hosts=$TARGET_HOST:9200,$TARGET_HOST:9201 \
        --client-options=use_ssl:false,verify_certs:false,timeout:60 \
        --kill-running-processes --include-tasks=index \
        --workload-params=bulk_indexing_clients:$clients,bulk_size:10000"
    
    log "About to execute OSB command..."
    
    # Start metrics collection in background
    (
        local sample=1
        while kill -0 $$ 2>/dev/null; do
            collect_metrics "$metrics_file" "$sample"
            sample=$((sample + 1))
            sleep 60
        done
    ) &
    local metrics_pid=$!
    
    if ! eval "$osb_cmd" > "$osb_log" 2>&1; then
        kill $metrics_pid 2>/dev/null
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
    
    # Stop metrics collection
    kill $metrics_pid 2>/dev/null
    
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
    
    # Calculate total configurations and runs
    local total_configs=$((${#CLIENT_LOADS[@]} * ${#NODE_SHARD_CONFIGS[@]}))
    local total_runs=$((total_configs * REPETITIONS))
    log "Total configurations: $total_configs, Total runs: $total_runs"
    log "CLIENT_LOADS: ${CLIENT_LOADS[*]}"
    log "NODE_SHARD_CONFIGS: ${NODE_SHARD_CONFIGS[*]}"
    
    load_checkpoint
    
    local completed_runs=0
    local found_resume_point=false
    
    for clients in "${CLIENT_LOADS[@]}"; do
        for node_shard in "${NODE_SHARD_CONFIGS[@]}"; do
            local nodes=$node_shard
            local shards=$node_shard
            
            # If we haven't found our resume point yet, check if this is it
            if [[ $found_resume_point == false ]]; then
                if [[ $clients -gt $CURRENT_CLIENTS ]] || \
                   [[ $clients -eq $CURRENT_CLIENTS && $nodes -gt $CURRENT_NODES ]]; then
                    found_resume_point=true
                    log "Found resume point: $clients clients, $nodes nodes"
                elif [[ $clients -eq $CURRENT_CLIENTS && $nodes -eq $CURRENT_NODES ]]; then
                    # Same config - check if we need to resume mid-repetitions
                    found_resume_point=true
                    log "Resuming within same config: $clients clients, $nodes nodes"
                else
                    # Skip this entire configuration
                    completed_runs=$((completed_runs + REPETITIONS))
                    continue
                fi
            fi
            
            # Configure cluster once per node/shard combination
            log "About to configure cluster: $nodes nodes, $shards shards"
            configure_cluster "$nodes" "$shards"
            log "Cluster configured, verifying..."
            verify_cluster_active
            log "Cluster verified, starting benchmark runs..."
            
            for rep in $(seq 1 $REPETITIONS); do
                log "Processing repetition $rep for $clients clients, $nodes nodes, $shards shards"
                
                # Skip completed repetitions in current config
                if [[ $clients -eq $CURRENT_CLIENTS && $nodes -eq $CURRENT_NODES && $rep -le $CURRENT_REP ]]; then
                    log "Skipping completed repetition: $clients,$nodes,$rep (completed up to $CURRENT_REP)"
                    completed_runs=$((completed_runs + 1))
                    continue
                fi
                
                log "Running new benchmark: $clients,$nodes,$rep"
                
                if run_benchmark "$clients" "$nodes" "$shards" "$rep"; then
                    log "run_benchmark completed successfully"
                    save_checkpoint "$clients" "$nodes" "$shards" "$rep"
                else
                    log "run_benchmark failed, but continuing..."
                fi
                
                completed_runs=$((completed_runs + 1))
                
                log "Progress: $completed_runs/$total_runs runs completed"
            done
        done
    done
    
    rm -f "$CHECKPOINT_FILE"
    log "Performance test suite completed successfully"
}

main "$@"
