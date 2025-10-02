#!/bin/bash

CLUSTER_HOST="10.0.0.209"
RESULTS_DIR="./results/c4a-16/nyc_taxis"

check_cluster_ready() {
    local run_num=$1
    echo "Checking cluster readiness for run $run_num..."
    
    while true; do
        # Check for active merges
        merges=$(curl -s "http://$CLUSTER_HOST:9200/_cat/nodes?h=segments.index_writer_memory&format=json" | jq -r '.[].segments.index_writer_memory' | grep -v "0b" | wc -l)
        
        if [ "$merges" -eq 0 ]; then
            echo "Active merges: 0"
            echo "Cluster ready for run $run_num"
            break
        else
            echo "Active merges detected: $merges. Waiting 30s..."
            sleep 30
        fi
    done
}

# Initial cleanup
echo "Initial cleanup before run 1..."
curl -XDELETE "http://$CLUSTER_HOST:9200/nyc*"
check_cluster_ready 1

# Run benchmarks 5 times
for i in {1..5}; do
    echo "Starting OSB run $i/5..."
    
    script -c "opensearch-benchmark run --workload=nyc_taxis --pipeline=benchmark-only --target-hosts=$CLUSTER_HOST:9200,$CLUSTER_HOST:9201,$CLUSTER_HOST:9202,$CLUSTER_HOST:9203,$CLUSTER_HOST:9204,$CLUSTER_HOST:9205,$CLUSTER_HOST:9206,$CLUSTER_HOST:9207 --client-options=use_ssl:false,verify_certs:false,timeout:60 --kill-running-processes --include-tasks=index --workload-params=bulk_indexing_clients:60,bulk_size:10000" "$RESULTS_DIR/$i.log"
    
    echo "Run $i completed. Cleaning up..."
    curl -XDELETE "http://$CLUSTER_HOST:9200/nyc*"
    
    if [ $i -lt 5 ]; then
        check_cluster_ready $((i+1))
    fi
done

echo "All 5 benchmark runs completed. Results saved in $RESULTS_DIR/"
