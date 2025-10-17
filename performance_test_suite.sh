#!/bin/bash

# Test parameters
TIMESTAMP="nyc_taxi_1015_index_0"
CLIENT_LOADS=(60)
REPETITIONS=4

set -euo pipefail

# Initialize parameters
WORKLOAD_PARAM=""
INCLUDE_TASKS_PARAM=""
DRY_RUN=false
CLIENTS_PARAM=""

usage() {
    echo "Usage: $0 --workload <workload> [options]"
    echo ""
    echo "Required parameter:"
    echo "  --workload <name>      Workload name (nyc_taxis, big5, vectorsearch)"
    echo ""
    echo "Optional parameters:"
    echo "  --include-tasks <list> Tasks to include in OSB benchmark (e.g., index, search)"
    echo "  --clients <count>      Client count (default: 60)"
    echo "  --repetitions <num>    Number of repetitions per config (default: 4)"
    echo "  --dry-run              Show commands without executing them"
    echo ""
    echo "Examples:"
    echo "  $0 --workload nyc_taxis"
    echo "  $0 --workload nyc_taxis --include-tasks index"
    echo "  $0 --workload nyc_taxis --clients 60"
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --workload)
            WORKLOAD_PARAM="$2"
            shift 2
            ;;
        --include-tasks)
            INCLUDE_TASKS_PARAM="$2"
            shift 2
            ;;
        --clients)
            CLIENTS_PARAM="$2"
            shift 2
            ;;
        --repetitions)
            REPETITIONS="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "ERROR: Unknown parameter '$1'"
            usage
            ;;
    esac
done

# Validate required parameters
if [[ -z "$WORKLOAD_PARAM" ]]; then
    echo "ERROR: --workload parameter is required"
    usage
fi

ALLOWED_WORKLOADS=("nyc_taxis" "big5" "vectorsearch")
if [[ ! " ${ALLOWED_WORKLOADS[*]} " =~ " ${WORKLOAD_PARAM} " ]]; then
    echo "ERROR: Invalid workload '$WORKLOAD_PARAM'"
    echo "Allowed workloads: ${ALLOWED_WORKLOADS[*]}"
    exit 1
fi

# Convert parameters to single values
if [[ -n "$CLIENTS_PARAM" ]]; then
    CLIENT_LOADS=($CLIENTS_PARAM)
fi

# Set required variables
WORKLOAD_NAME="$WORKLOAD_PARAM"
TARGET_HOST="${IP:-localhost}"

log() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")] $*"
}

run_benchmark() {
    local clients=$1
    local rep=$2
    
    local test_name="${clients}_${rep}"
    
    log "Starting benchmark: $test_name"
    
    # Prepare cluster before OSB execution
    log "Preparing cluster for benchmark..."
    
    if ! IP="$TARGET_HOST" ./install/dual_installer.sh drop; then
        log "Failed to drop indices"
        return 1
    fi
    
    # Generate OSB command using dual_installer.sh
    local osb_cmd_args="--workload $WORKLOAD_NAME --clients $clients"
    if [[ -n "$INCLUDE_TASKS_PARAM" ]]; then
        osb_cmd_args="$osb_cmd_args --include-tasks $INCLUDE_TASKS_PARAM"
    fi
    
    local osb_cmd
    if ! osb_cmd=$(IP="$TARGET_HOST" ./install/dual_installer.sh osb_command $osb_cmd_args); then
        log "Failed to generate OSB command"
        return 1
    fi
    
    log "Executing OSB run, please wait for completion."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY RUN: Skipping OSB execution"
        return 0
    fi
    
    # Create nyc_taxis index
    log "Creating nyc_taxis index..."
    if ! ssh "$TARGET_HOST" "curl -X PUT 'localhost:9200/nyc_taxis' -H 'Content-Type: application/json' >/dev/null 2>&1"; then
        log "Failed to create nyc_taxis index"
        return 1
    fi
    
    # Skip shard validation since we removed shard parameters
    log "No specific shard count specified, skipping shard validation"
    sleep 2  # Brief wait for index to be ready
    
    log "Starting OSB execution..."
    log ""
    log "$osb_cmd"
    log ""
    if ! bash -c "$osb_cmd"; then
        log "OSB execution failed for $test_name"
        return 1
    fi
    
    log "OSB execution completed for $test_name"
    return 0
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
    
    # Calculate total runs
    local total_runs=$((${#CLIENT_LOADS[@]} * REPETITIONS))
    log "Total runs: $total_runs"
    log "CLIENT_LOADS: ${CLIENT_LOADS[*]}"

    local completed_runs=0
    
    # Simple loop without checkpoint logic
    for clients in "${CLIENT_LOADS[@]}"; do
        for rep in $(seq 1 $REPETITIONS); do
            log "Processing repetition $rep for $clients clients"
            log "Running benchmark: $clients,$rep"

            if run_benchmark "$clients" "$rep"; then
                log "run_benchmark completed successfully"
            else
                log "run_benchmark failed, but continuing..."
            fi
            
            completed_runs=$((completed_runs + 1))
            log "Progress: $completed_runs/$total_runs runs completed"
        done
    done
    
    log "Performance test suite completed successfully"
}

# Execute main function
main
