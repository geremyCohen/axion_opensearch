#!/bin/bash

# OpenSearch Heap Usage Monitoring Script
# Usage: ./heap_stats.sh [host:port]

HOST="${1:-127.0.0.1:9200}"

show_menu() {
  echo "=== OpenSearch Heap Monitoring Options ==="
  echo "1. Simple Node Overview"
  echo "2. Detailed Per-Node Stats" 
  echo "3. Cluster-Wide Memory Summary"
  echo "4. All Charts (default)"
  echo
  read -p "Select option (1-4) or press Enter for all: " choice
  echo
}

show_simple() {
  curl -s "http://$HOST/_cat/nodes?v&h=name,heap.percent,heap.current,heap.max"
  echo
  # Calculate average heap percentage
  avg_heap=$(curl -s "http://$HOST/_cat/nodes?h=heap.percent" | awk '{sum+=$1; count++} END {if(count>0) printf "%.1f", sum/count}')
  echo "Average Heap Usage: ${avg_heap}%"
}

show_detailed() {
  curl -s "http://$HOST/_nodes/stats/jvm?pretty" | jq '.nodes | to_entries[] | {node: .value.name, heap_used_percent: .value.jvm.mem.heap_used_percent, heap_used_gb: (.value.jvm.mem.heap_used_in_bytes / 1073741824 | round), heap_max_gb: (.value.jvm.mem.heap_max_in_bytes / 1073741824 | round)}'
}

show_cluster() {
  curl -s "http://$HOST/_cluster/stats?pretty" | jq '.nodes.jvm.mem'
}

show_all() {
  echo "1. Simple Node Overview:"
  show_simple
  echo
  echo "2. Detailed Per-Node Stats:"
  show_detailed
  echo
  echo "3. Cluster-Wide Memory Summary:"
  show_cluster
}

# Get user choice once
show_menu
case $choice in
  1) chart_func="show_simple" ;;
  2) chart_func="show_detailed" ;;
  3) chart_func="show_cluster" ;;
  *) chart_func="show_all" ;;
esac

while true; do
  clear
  echo "=== OpenSearch Heap Usage Stats for $HOST ($(date)) ==="
  echo
  
  $chart_func
  
  echo
  echo "Press Ctrl+C to exit. Refreshing in 1 second..."
  sleep 1
done
