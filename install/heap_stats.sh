#!/bin/bash

# OpenSearch Heap Usage Monitoring Script
# Usage: ./heap_stats.sh [host:port]

HOST="${1:-127.0.0.1:9200}"

echo "=== OpenSearch Heap Usage Stats for $HOST ==="
echo

echo "1. Simple Node Overview:"
curl -s "http://$HOST/_cat/nodes?v&h=name,heap.percent,heap.current,heap.max"
echo

echo "2. Detailed Per-Node Stats:"
curl -s "http://$HOST/_nodes/stats/jvm?pretty" | jq '.nodes | to_entries[] | {node: .value.name, heap_used_percent: .value.jvm.mem.heap_used_percent, heap_used_gb: (.value.jvm.mem.heap_used_in_bytes / 1073741824 | round), heap_max_gb: (.value.jvm.mem.heap_max_in_bytes / 1073741824 | round)}'
echo

echo "3. Cluster-Wide Memory Summary:"
curl -s "http://$HOST/_cluster/stats?pretty" | jq '.nodes.jvm.mem'
