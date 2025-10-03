#!/bin/bash

set -uo pipefail

# Test parameters - 8 total runs (2 configs × 4 reps each)
CLIENT_LOADS=(60 70)
NODE_CONFIGS=(16 20)
SHARD_CONFIGS=(16 20)
REPETITIONS=4

log() {
    echo "[$(date -Iseconds)] $*"
}

main() {
    log "Starting debug test - tracing execution flow"
    
    local completed_runs=0
    
    for clients in "${CLIENT_LOADS[@]}"; do
        log "=== Processing client load: $clients ==="
        
        for nodes in "${NODE_CONFIGS[@]}"; do
            log "--- Processing node config: $nodes ---"
            
            for shards in "${SHARD_CONFIGS[@]}"; do
                log "+++ Processing shard config: $shards +++"
                
                # Skip invalid combinations
                if [[ $shards -gt $nodes ]]; then
                    log "SKIP: $shards shards > $nodes nodes"
                    continue
                fi
                
                log "CONFIGURE: $nodes nodes, $shards shards"
                
                for rep in $(seq 1 $REPETITIONS); do
                    log ">>> Processing repetition: $rep <<<"
                    
                    local test_name="${clients}_${nodes}-${shards}_${rep}"
                    log "RUN: $test_name"
                    
                    ((completed_runs++))
                    log "Progress: $completed_runs/8 runs completed"
                done
            done
        done
    done
    
    log "Debug test completed - expected 8 runs, actual: $completed_runs"
}

main "$@"
