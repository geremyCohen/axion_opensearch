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
  echo "Cluster-Wide Memory Summary:"
  curl -s "http://$HOST/_cluster/stats?pretty" | jq '.nodes.jvm.mem'
  echo
  
  echo "Cluster-Wide Max Values & Usage:"
  # Get heap stats
  local heap_data=$(curl -s "http://$HOST/_nodes/stats/jvm?pretty" | jq -r '.nodes | to_entries[] | "\(.value.jvm.mem.heap_used_percent) \(.value.jvm.mem.heap_used_in_bytes) \(.value.jvm.mem.heap_max_in_bytes)"')
  
  # Calculate heap maximums
  local max_heap_percent=$(echo "$heap_data" | awk '{if($1>max) max=$1} END {print max}')
  local total_heap_used=$(echo "$heap_data" | awk '{sum+=$2} END {print sum}')
  local total_heap_max=$(echo "$heap_data" | awk '{sum+=$3} END {print sum}')
  local cluster_heap_percent=$(echo "$total_heap_used $total_heap_max" | awk '{printf "%.1f", ($1/$2)*100}')
  
  echo "  Max Heap Usage: ${max_heap_percent}% (highest node)"
  echo "  Cluster Heap Usage: ${cluster_heap_percent}% ($(echo "$total_heap_used" | awk '{printf "%.1fGB", $1/1073741824}') / $(echo "$total_heap_max" | awk '{printf "%.1fGB", $1/1073741824}'))"
  
  # Get circuit breaker settings from cluster settings
  echo
  echo "Circuit Breaker Configuration:"
  local settings=$(curl -s "http://$HOST/_cluster/settings?include_defaults=true&pretty" 2>/dev/null)
  
  # Extract breaker settings from persistent settings first, then defaults
  local total_limit=$(echo "$settings" | jq -r '.persistent.indices.breaker.total.limit // .defaults."indices.breaker.total.limit" // "70%"' 2>/dev/null || echo "70%")
  local request_limit=$(echo "$settings" | jq -r '.persistent.indices.breaker.request.limit // .defaults."indices.breaker.request.limit" // "60%"' 2>/dev/null || echo "60%")
  local fielddata_limit=$(echo "$settings" | jq -r '.persistent.indices.breaker.fielddata.limit // .defaults."indices.breaker.fielddata.limit" // "40%"' 2>/dev/null || echo "40%")
  
  printf "%-25s %s\n" "Setting" "Limit"
  printf "%-25s %s\n" "-------" "-----"
  printf "%-25s %s\n" "indices.breaker.total" "$total_limit"
  printf "%-25s %s\n" "indices.breaker.request" "$request_limit"
  printf "%-25s %s\n" "indices.breaker.fielddata" "$fielddata_limit"
  
  # Get current breaker usage in readable format
  echo
  echo "Circuit Breaker Usage:"
  printf "%-15s %-12s %-12s %s\n" "Breaker" "Used" "Limit" "Usage%"
  printf "%-15s %-12s %-12s %s\n" "-------" "----" "-----" "------"
  
  # Get actual breaker stats with current limits
  curl -s "http://$HOST/_nodes/stats/breaker?pretty" | jq -r --arg total_pct "$total_limit" --arg request_pct "$request_limit" --arg fielddata_pct "$fielddata_limit" '
    .nodes | to_entries[0] | .value.breakers | to_entries[] | 
    select(.key | test("request|fielddata|total")) | 
    [.key, .value.estimated_size, .value.limit_size, .value.estimated_size_in_bytes, .value.limit_size_in_bytes] | @tsv
  ' 2>/dev/null | while IFS=$'\t' read breaker used limit used_bytes limit_bytes; do
    if [ "$limit_bytes" -gt 0 ]; then
      percent=$(echo "$used_bytes $limit_bytes" | awk '{printf "%.1f", ($1/$2)*100}')
    else
      percent="0.0"
    fi
    printf "%-15s %-12s %-12s %s%%\n" "$breaker" "$used" "$limit" "$percent"
  done

  # Thread Pool Analysis
  echo
  echo "Thread Pool Status (Bottleneck Analysis):"
  printf "%-15s %-8s %-8s %-8s %-10s %-10s\n" "Pool" "Active" "Queue" "Rejected" "Completed" "Largest"
  printf "%-15s %-8s %-8s %-8s %-10s %-10s\n" "----" "------" "-----" "--------" "---------" "-------"
  
  curl -s "http://$HOST/_nodes/stats/thread_pool?pretty" | jq -r '.nodes | to_entries[0] | .value.thread_pool | to_entries[] | select(.key | test("write|bulk|search|get")) | [.key, .value.active, .value.queue, .value.rejected, .value.completed, .value.largest] | @tsv' 2>/dev/null | while IFS=$'\t' read pool active queue rejected completed largest; do
    printf "%-15s %-8s %-8s %-8s %-10s %-10s\n" "$pool" "$active" "$queue" "$rejected" "$completed" "$largest"
  done

  # Indexing Performance Metrics
  echo
  echo "Indexing Performance Metrics:"
  local indexing_stats=$(curl -s "http://$HOST/_nodes/stats/indices?pretty" | jq '.nodes | to_entries[0] | .value.indices.indexing')
  echo "  Index Rate: $(echo "$indexing_stats" | jq -r '.index_total // 0') total docs, $(echo "$indexing_stats" | jq -r '.index_current // 0') current"
  echo "  Index Time: $(echo "$indexing_stats" | jq -r '.index_time_in_millis // 0')ms total"
  echo "  Throttle Time: $(echo "$indexing_stats" | jq -r '.throttle_time_in_millis // 0')ms"
  
  # Merge Activity (CPU stall indicator)
  local merge_stats=$(curl -s "http://$HOST/_nodes/stats/indices?pretty" | jq '.nodes | to_entries[0] | .value.indices.merges')
  echo "  Active Merges: $(echo "$merge_stats" | jq -r '.current // 0')"
  echo "  Merge Throttle: $(echo "$merge_stats" | jq -r '.total_throttled_time_in_millis // 0')ms"

  # System Resource Usage
  echo
  echo "System Resource Usage:"
  local host_ip=$(echo "$HOST" | cut -d: -f1)
  if [ "$host_ip" != "127.0.0.1" ] && [ "$host_ip" != "localhost" ]; then
    echo "  CPU Usage: $(ssh "$host_ip" "top -bn1 | grep 'Cpu(s)' | awk '{print \$2}'" 2>/dev/null || echo "N/A")"
    echo "  Load Average: $(ssh "$host_ip" "uptime | awk -F'load average:' '{print \$2}'" 2>/dev/null || echo "N/A")"
    echo "  Disk I/O: $(ssh "$host_ip" "iostat -x 1 1 2>/dev/null | tail -n +4 | awk 'NR>3 {print \$1 \": \" \$10 \"% util\"}' | head -3" 2>/dev/null || echo "iostat not available")"
  else
    echo "  CPU Usage: $(top -bn1 | grep 'Cpu(s)' | awk '{print $2}' 2>/dev/null || echo "N/A")"
    echo "  Load Average: $(uptime | awk -F'load average:' '{print $2}' 2>/dev/null || echo "N/A")"
  fi
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
