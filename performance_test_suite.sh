#!/bin/bash

set -euo pipefail

# Command line parameter validation
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <workload>"
    echo ""
    echo "Required parameter:"
    echo "  workload    Must be one of: nyc_taxis, big5, vectorsearch"
    echo ""
    echo "Example: $0 nyc_taxis"
    exit 1
fi

WORKLOAD_PARAM="$1"
ALLOWED_WORKLOADS=("nyc_taxis" "big5" "vectorsearch")

# Validate workload parameter
if [[ ! " ${ALLOWED_WORKLOADS[*]} " =~ " ${WORKLOAD_PARAM} " ]]; then
    echo "ERROR: Invalid workload '$WORKLOAD_PARAM'"
    echo ""
    echo "Usage: $0 <workload>"
    echo ""
    echo "Allowed workloads:"
    for workload in "${ALLOWED_WORKLOADS[@]}"; do
        echo "  - $workload"
    done
    echo ""
    echo "Example: $0 nyc_taxis"
    exit 1
fi

echo "Starting performance test suite with workload: $WORKLOAD_PARAM"

# Configuration
TARGET_HOST="$IP"

# Path configuration - consolidate all path components
WORKLOAD_NAME="$WORKLOAD_PARAM"
BASE_RESULTS_DIR="./results/optimization"

# Detect instance type on remote host
INSTANCE_TYPE_RAW=$(ssh "$TARGET_HOST" "curl -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/machine-type 2>/dev/null | awk -F'/' '{print \$NF}'" 2>/dev/null || echo "c4a-standard-64")
# Remove "standard" from the instance type (e.g., c4a-standard-16 -> c4a-16)
INSTANCE_TYPE=$(echo "$INSTANCE_TYPE_RAW" | sed 's/-standard-/-/')

# Detect page size on remote host
PAGE_SIZE=$(ssh "$TARGET_HOST" "getconf PAGESIZE" 2>/dev/null || echo "4096")
if [[ "$PAGE_SIZE" == "65536" ]]; then
    PAGE_SIZE_DIR="64k"
else
    PAGE_SIZE_DIR="4k"
fi

# Find existing run or create new timestamp
if [[ -d "$BASE_RESULTS_DIR" ]]; then
    EXISTING_RUN=$(find "$BASE_RESULTS_DIR" -name "test_progress.checkpoint" -type f 2>/dev/null | head -1)
else
    EXISTING_RUN=""
fi

TIMESTAMP="20251008"
echo "Using existing run: $TIMESTAMP"
echo "Detected instance type: $INSTANCE_TYPE_RAW -> $INSTANCE_TYPE"
echo "Detected page size: $PAGE_SIZE bytes -> using $PAGE_SIZE_DIR directory"

# Consolidated path construction
RUN_BASE_DIR="$BASE_RESULTS_DIR/$TIMESTAMP"
INSTANCE_BASE_DIR="$RUN_BASE_DIR/$INSTANCE_TYPE/$PAGE_SIZE_DIR"
RESULTS_DIR="$INSTANCE_BASE_DIR/$WORKLOAD_NAME"
CHECKPOINT_FILE="$RUN_BASE_DIR/test_progress.checkpoint"
LOG_FILE="$RUN_BASE_DIR/performance_test.log"

# Test parameters
CLIENT_LOADS=(60 70 80 90 100)
NODE_SHARD_CONFIGS=(16 20 24 28 32)  # nodes=shards for each value
REPETITIONS=4
#REPETITIONS=4

# Initialize
mkdir -p "$RESULTS_DIR"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

error_exit() {
    log "ERROR: $*"
    exit 1
}

load_checkpoint() {
    if [[ -f "$CHECKPOINT_FILE" ]]; then
        source "$CHECKPOINT_FILE"
        log "Checkpoint found: resuming from clients=$CURRENT_CLIENTS, nodes=$CURRENT_NODES, shards=$CURRENT_SHARDS, rep=$CURRENT_REP"
        
        # Checkpoint loaded successfully
        
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

aggressive_index_reset() {
    local expected_shards=$1
    log "Performing aggressive index reset for $expected_shards shards..."
    
    # Delete all indices multiple times to ensure cleanup
    for attempt in {1..3}; do
        log "Index deletion attempt $attempt/3"
        curl -s -X DELETE "http://$TARGET_HOST:9200/*" > /dev/null 2>&1 || true
        curl -s -X DELETE "http://$TARGET_HOST:9200/${WORKLOAD_NAME}*" > /dev/null 2>&1 || true
        curl -s -X DELETE "http://$TARGET_HOST:9200/_all" > /dev/null 2>&1 || true
        sleep 3
        
        # Check if workload index still exists
        local indices_exist=$(curl -s "http://$TARGET_HOST:9200/_cat/indices/${WORKLOAD_NAME}*" 2>/dev/null | wc -l)
        if [[ $indices_exist -eq 0 ]]; then
            log "Index deletion successful on attempt $attempt"
            break
        fi
        log "Indices still exist, retrying deletion..."
    done
    
    # Wait for deletion to propagate
    sleep 10
    
    # Verify no workload indices remain
    local remaining_indices=$(curl -s "http://$TARGET_HOST:9200/_cat/indices/${WORKLOAD_NAME}*" 2>/dev/null | wc -l)
    if [[ $remaining_indices -gt 0 ]]; then
        log "WARNING: $remaining_indices $WORKLOAD_NAME indices still exist after aggressive cleanup"
        curl -s "http://$TARGET_HOST:9200/_cat/indices/${WORKLOAD_NAME}*" 2>/dev/null | while read line; do
            log "Remaining index: $line"
        done
    else
        log "All $WORKLOAD_NAME indices successfully deleted"
    fi
}

verify_shard_configuration() {
    local expected_shards=$1
    log "Verifying shard configuration expects $expected_shards shards..."
    
    # Wait for any indices to be created and check shard count
    local max_attempts=10
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        local workload_indices=$(curl -s "http://$TARGET_HOST:9200/_cat/indices/${WORKLOAD_NAME}*" 2>/dev/null)

        if [[ -n "$workload_indices" ]]; then
            log "Found $WORKLOAD_NAME indices:"
            echo "$workload_indices" | while read line; do
                log "  $line"
            done
            
            # Check primary shard count
            local actual_shards=$(curl -s "http://$TARGET_HOST:9200/_cat/shards/${WORKLOAD_NAME}*?h=shard,prirep" 2>/dev/null | grep "p" | wc -l)
            log "Actual primary shards: $actual_shards, Expected: $expected_shards"
            
            if [[ $actual_shards -ne $expected_shards ]]; then
                log "ERROR: Shard count mismatch! Deleting incorrect index..."
                curl -s -X DELETE "http://$TARGET_HOST:9200/${WORKLOAD_NAME}*" > /dev/null 2>&1 || true
                sleep 5
            else
                log "Shard configuration verified successfully"
                return 0
            fi
        else
            log "No $WORKLOAD_NAME indices found (attempt $attempt/$max_attempts)"
        fi
        
        sleep 5
        ((attempt++))
    done
    
    log "Shard verification completed"
    return 0
}

recover_cluster_from_split_brain() {
    log "Attempting cluster recovery from split-brain/quorum failure..."
    
    # Check if we have cluster_master_not_discovered_exception
    local health_response=$(curl -s --connect-timeout 10 "http://$TARGET_HOST:9200/_cluster/health" 2>/dev/null)
    if echo "$health_response" | grep -q "cluster_master_not_discovered_exception"; then
        log "Detected cluster manager election failure - performing full cluster restart"
        
        # Stop all OpenSearch services
        log "Stopping all OpenSearch services..."
        ssh "$TARGET_HOST" "sudo systemctl stop opensearch-node*" 2>/dev/null || true
        sleep 10
        
        # Clear cluster state data to force fresh election
        log "Clearing cluster state data..."
        ssh "$TARGET_HOST" "sudo rm -rf /opt/opensearch-node*/data/nodes/*/indices/*" 2>/dev/null || true
        ssh "$TARGET_HOST" "sudo rm -rf /opt/opensearch-node*/data/nodes/*/node.lock" 2>/dev/null || true
        
        # Start services sequentially to ensure proper cluster formation
        log "Starting OpenSearch services sequentially..."
        for node in {1..16}; do
            ssh "$TARGET_HOST" "sudo systemctl start opensearch-node$node" 2>/dev/null || true
            sleep 2
        done
        
        # Wait for cluster to form
        log "Waiting for cluster formation..."
        local attempts=0
        while [[ $attempts -lt 30 ]]; do
            local health=$(curl -s --connect-timeout 10 "http://$TARGET_HOST:9200/_cluster/health" 2>/dev/null)
            if echo "$health" | grep -q '"status"'; then
                local status=$(echo "$health" | jq -r '.status // "unknown"' 2>/dev/null)
                local nodes=$(echo "$health" | jq -r '.number_of_nodes // 0' 2>/dev/null)
                log "Cluster recovery progress: status=$status, nodes=$nodes"
                
                if [[ "$status" != "unknown" && $nodes -gt 0 ]]; then
                    log "Cluster recovery successful"
                    return 0
                fi
            fi
            sleep 10
            ((attempts++))
        done
        
        log "WARNING: Cluster recovery may have failed"
        return 1
    fi
    
    return 0
}

safe_delete_indices() {
    curl -s -X DELETE "http://${TARGET_HOST}:9200/${WORKLOAD_NAME}*" >/dev/null 2>&1 || true
}

detect_cluster_issues() {
    local health=$(curl -s "${TARGET_HOST}:9200/_cluster/health" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
    [[ "$health" == "green" ]]
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

wait_for_cluster_with_timeout() {
    local max_attempts=10
    local attempt=1
    
    log "Waiting for cluster health with timeout..."
    
    while [[ $attempt -le $max_attempts ]]; do
        local health_response=$(curl -s --connect-timeout 10 "http://$TARGET_HOST:9200/_cluster/health" 2>/dev/null)
        
        if [[ -n "$health_response" ]]; then
            # Check for cluster manager election failure
            if echo "$health_response" | grep -q "cluster_master_not_discovered_exception"; then
                log "Detected cluster manager election failure - attempting recovery"
                if recover_cluster_from_split_brain; then
                    continue  # Retry health check after recovery
                else
                    log "Cluster recovery failed, but continuing"
                    return 1
                fi
            fi
            
            local status=$(echo "$health_response" | jq -r '.status // "unknown"' 2>/dev/null)
            local nodes=$(echo "$health_response" | jq -r '.number_of_nodes // 0' 2>/dev/null)
            local unassigned=$(echo "$health_response" | jq -r '.unassigned_shards // 0' 2>/dev/null)
            
            log "Cluster check: status=$status, nodes=$nodes, unassigned=$unassigned (attempt $attempt/$max_attempts)"
            
            if [[ "$status" == "green" || "$status" == "yellow" ]] && [[ $unassigned -eq 0 ]]; then
                log "Cluster is healthy"
                return 0
            fi
            
            if [[ "$status" == "red" && $unassigned -gt 0 ]]; then
                log "Red cluster with unassigned shards - attempting recovery"
                curl -s -X DELETE "http://$TARGET_HOST:9200/${WORKLOAD_NAME}*" > /dev/null 2>&1 || true
                sleep 5
            fi
        else
            log "No cluster response (attempt $attempt/$max_attempts)"
        fi
        
        sleep 15
        ((attempt++))
    done
    
    log "Cluster health check timed out after $max_attempts attempts"
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
    
    # Always perform aggressive index reset before cluster operations
    log "Performing aggressive index reset..."
    aggressive_index_reset "$shards"
    
    # Check for red status and attempt recovery
    local cluster_status=$(curl -s --connect-timeout 10 "http://$TARGET_HOST:9200/_cluster/health" 2>/dev/null | jq -r '.status // "unknown"' 2>/dev/null)
    if [[ "$cluster_status" == "red" ]]; then
        log "Cluster is red - attempting recovery before scaling"
        local unassigned=$(curl -s --connect-timeout 10 "http://$TARGET_HOST:9200/_cluster/health" 2>/dev/null | jq -r '.unassigned_shards // 0' 2>/dev/null)
        if [[ $unassigned -gt 0 ]]; then
            log "Found $unassigned unassigned shards - forcing index cleanup"
            curl -s -X DELETE "http://$TARGET_HOST:9200/*" > /dev/null 2>&1 || true
            sleep 10
            
            # Recheck status after cleanup
            cluster_status=$(curl -s --connect-timeout 10 "http://$TARGET_HOST:9200/_cluster/health" 2>/dev/null | jq -r '.status // "unknown"' 2>/dev/null)
            log "Cluster status after cleanup: $cluster_status"
        fi
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
    
    # Post-scaling validation with timeout
    sleep 30
    log "Post-scaling validation with timeout..."
    
    if ! wait_for_cluster_with_timeout; then
        log "WARNING: Cluster not fully healthy after scaling, but continuing"
    fi
    
    # Verify shard configuration is correct
    verify_shard_configuration "$shards"
    
    log "Cluster scaling completed"
}

verify_cluster_active() {
    log "Verifying cluster is ready for benchmarking..."
    
    # Use the timeout-based health check
    if wait_for_cluster_with_timeout; then
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
    
    # Aggressive index cleanup before benchmark
    log "Performing aggressive index cleanup before benchmark..."
    aggressive_index_reset "$shards"
    
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
    
    local osb_cmd="opensearch-benchmark run --workload=$WORKLOAD_NAME \
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
        # Skip entire client loads that are already complete
        if [[ $clients -lt $CURRENT_CLIENTS ]]; then
            log "Skipping completed client load: $clients clients"
            completed_runs=$((completed_runs + ${#NODE_SHARD_CONFIGS[@]} * REPETITIONS))
            continue
        elif [[ $clients -eq $CURRENT_CLIENTS ]]; then
            # For current client load, check if we're completely done with all configs
            # We're done if current_nodes is the last node config AND current_rep equals REPETITIONS
            local last_node_config=${NODE_SHARD_CONFIGS[-1]}
            log "DEBUG: clients=$clients, CURRENT_CLIENTS=$CURRENT_CLIENTS, CURRENT_NODES=$CURRENT_NODES, last_node_config=$last_node_config, CURRENT_REP=$CURRENT_REP, REPETITIONS=$REPETITIONS"
            if [[ $CURRENT_NODES -eq $last_node_config && $CURRENT_REP -eq $REPETITIONS ]]; then
                log "Skipping completed client load: $clients clients (all configs done)"
                completed_runs=$((completed_runs + ${#NODE_SHARD_CONFIGS[@]} * REPETITIONS))
                continue
            fi
        fi
        
        for node_shard in "${NODE_SHARD_CONFIGS[@]}"; do
            local nodes=$node_shard
            local shards=$node_shard
            
            # If we haven't found our resume point yet, check if this is it
            if [[ $found_resume_point == false ]]; then
                # Check if we should resume from this configuration
                if [[ $clients -gt $CURRENT_CLIENTS ]]; then
                    # Next client load - this is our resume point
                    found_resume_point=true
                    log "Found resume point: $clients clients, $nodes nodes (next client load)"
                elif [[ $clients -eq $CURRENT_CLIENTS && $nodes -gt $CURRENT_NODES ]]; then
                    # Same client load, next node configuration
                    found_resume_point=true
                    log "Found resume point: $clients clients, $nodes nodes (next node config)"
                elif [[ $clients -eq $CURRENT_CLIENTS && $nodes -eq $CURRENT_NODES ]]; then
                    # Same config - check if we need to resume mid-repetitions
                    if [[ $CURRENT_REP -lt $REPETITIONS ]]; then
                        found_resume_point=true
                        log "Resuming within same config: $clients clients, $nodes nodes (rep $((CURRENT_REP + 1)))"
                    else
                        # All repetitions complete for this config, skip it
                        log "Skipping completed config: $clients clients, $nodes nodes (all $REPETITIONS reps done)"
                        completed_runs=$((completed_runs + REPETITIONS))
                        continue
                    fi
                elif [[ $clients -eq $CURRENT_CLIENTS && $nodes -lt $CURRENT_NODES ]]; then
                    # Earlier node config in same client load - skip it
                    log "Skipping earlier node config: $clients clients, $nodes nodes"
                    completed_runs=$((completed_runs + REPETITIONS))
                    continue
                else
                    # Skip this entire configuration - it's already completed
                    log "Skipping completed config: $clients clients, $nodes nodes"
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
