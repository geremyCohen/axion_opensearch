#!/bin/bash

set -euo pipefail

# Initialize parameters - all must be provided via command line
TIMESTAMP=""
CLIENT_LOADS=()
REPETITIONS=""
WORKLOAD_PARAM=""
INCLUDE_TASKS_PARAM=""
DRY_RUN=false

# Detect instance type and page size from remote host
# Detect instance type on remote host
INSTANCE_TYPE_RAW=$(ssh "$IP" "curl -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/machine-type 2>/dev/null | awk -F'/' '{print \$NF}'" 2>/dev/null || echo "c4a-standard-64")
# Remove "standard" from the instance type (e.g., c4a-standard-16 -> c4a-16)
INSTANCE_TYPE=$(echo "$INSTANCE_TYPE_RAW" | sed 's/-standard-/-/')

# Detect page size on remote host
PAGE_SIZE=$(ssh "$IP" "getconf PAGESIZE" 2>/dev/null || echo "4096")
if [[ "$PAGE_SIZE" == "65536" ]]; then
    PAGE_SIZE_DIR="64k"
else
    PAGE_SIZE_DIR="4k"
fi

set -euo pipefail

# Initialize parameters
WORKLOAD_PARAM=""
INCLUDE_TASKS_PARAM=""
DRY_RUN=false
CLIENTS_PARAM=""

usage() {
    echo "Usage: $0 --workload <workload> --timestamp <name> --clients <list> --repetitions <num> [options]"
    echo ""
    echo "Required parameters:"
    echo "  --workload <name>      Workload name (nyc_taxis, big5, vectorsearch)"
    echo "  --timestamp <name>     Results folder timestamp"
    echo "  --clients <list>       Comma-separated client counts (e.g., 24,60,90)"
    echo "  --repetitions <num>    Number of repetitions per config"
    echo ""
    echo "Optional parameters:"
    echo "  --include-tasks <list> Tasks to include in OSB benchmark (e.g., index, search)"
    echo "  --dry-run              Show commands without executing them"
    echo ""
    echo "Examples:"
    echo "  $0 --workload nyc_taxis --timestamp test_run_001 --clients 60 --repetitions 4"
    echo "  $0 --workload nyc_taxis --timestamp test_run_001 --clients 24,60,90 --repetitions 3 --include-tasks index"
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
            IFS=',' read -ra CLIENT_LOADS <<< "$2"
            shift 2
            ;;
        --repetitions)
            REPETITIONS="$2"
            shift 2
            ;;
        --timestamp)
            TIMESTAMP="$2"
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

# Validate required parameters
if [[ -z "$TIMESTAMP" ]]; then
    echo "ERROR: --timestamp is required"
    usage
fi

if [[ ${#CLIENT_LOADS[@]} -eq 0 ]]; then
    echo "ERROR: --clients is required"
    usage
fi

if [[ -z "$REPETITIONS" ]]; then
    echo "ERROR: --repetitions is required"
    usage
fi

# Set required variables
WORKLOAD_NAME="$WORKLOAD_PARAM"

log() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")] $*"
}

run_benchmark() {
    local clients=$1
    local rep=$2
    
    # Get cluster info for folder structure
    local node_count=$(IP="$IP" ./install/dual_installer.sh read | grep "Nodes:" | awk '{print $2}')
    local shard_count=$(IP="$IP" ./install/dual_installer.sh read | grep "shards:" | awk '{print $3}')
    
    # Create detailed folder structure: TIMESTAMP/INSTANCE_TYPE/PAGE_SIZE/WORKLOAD_NAME/
    local results_dir="results/optimizations/$TIMESTAMP/$INSTANCE_TYPE/$PAGE_SIZE_DIR/$WORKLOAD_NAME"
    local result_file="$results_dir/${clients}_${node_count}_${shard_count}_${rep}.json"
    
    local test_name="${clients}_${rep}"
    
    log "Starting benchmark: $test_name"
    log "Results will be saved to: $result_file"
    
    # Prepare cluster before OSB execution
    log "Preparing cluster for benchmark..."
    
    if ! IP="$IP" ./install/dual_installer.sh drop; then
        log "Failed to drop indices"
        return 1
    fi
    
    # Generate OSB command using dual_installer.sh
    local osb_cmd_args="--workload $WORKLOAD_NAME --clients $clients"
    if [[ -n "$INCLUDE_TASKS_PARAM" ]]; then
        osb_cmd_args="$osb_cmd_args --include-tasks $INCLUDE_TASKS_PARAM"
    fi
    
    local osb_cmd
    if ! osb_cmd=$(IP="$IP" ./install/dual_installer.sh osb_command $osb_cmd_args); then
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
    if ! ssh "$IP" "curl -X PUT 'localhost:9200/nyc_taxis' -H 'Content-Type: application/json' >/dev/null 2>&1"; then
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
    
    # Create results directory
    mkdir -p "$results_dir"
    
    # Execute OSB command
    if ! bash -c "$osb_cmd"; then
        log "OSB execution failed for $test_name"
        return 1
    fi
    
    # Find and copy the OSB JSON result file
    local osb_json_file=$(find ~/.benchmark/benchmarks/test-runs -name "test_run.json" -type f -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)
    
    if [[ -f "$osb_json_file" ]]; then
        cp "$osb_json_file" "$result_file"
        log "Results copied to: $result_file"
    else
        log "Warning: OSB JSON result file not found in test-runs"
        touch "$result_file"  # Create empty file to maintain structure
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
    log "Results structure: results/optimizations/$TIMESTAMP/$INSTANCE_TYPE/$PAGE_SIZE_DIR/$WORKLOAD_NAME/"
    
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
