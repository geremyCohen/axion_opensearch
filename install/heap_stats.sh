#!/bin/bash

# OpenSearch Heap Usage Monitor
# Usage: ./heap_stats.sh [host:port]
# Default: localhost:9200

HOST="${1:-127.0.0.1:9200}"

show_menu() {
  echo "=== OpenSearch Heap Monitoring Options ==="
  echo "1. Simple Node Overview"
  echo "2. Detailed Per-Node Stats" 
  echo "3. Cluster-Wide Memory Summary"
  echo "4. CPU and System Stats"
  echo "5. All Charts (default)"
  echo
  read -p "Select option (1-5) or press Enter for all: " choice
  echo
}

show_simple() {
  curl -s "http://$HOST/_cat/nodes?v&h=name,heap.percent,heap.current,heap.max"
}

show_detailed() {
  echo "Per-Node Heap Details:"
  curl -s "http://$HOST/_nodes/stats/jvm?pretty" | jq -r '.nodes | to_entries[] | "Node: \(.value.name)\n  Heap Used: \(.value.jvm.mem.heap_used_percent)% (\(.value.jvm.mem.heap_used) / \(.value.jvm.mem.heap_max))\n  GC Collections: Young=\(.value.jvm.gc.collectors.young.collection_count), Old=\(.value.jvm.gc.collectors.old.collection_count)\n  GC Time: Young=\(.value.jvm.gc.collectors.young.collection_time_in_millis)ms, Old=\(.value.jvm.gc.collectors.old.collection_time_in_millis)ms\n"'
}

show_cpu() {
  echo "CPU and System Performance Stats:"
  local host_ip=$(echo "$HOST" | cut -d: -f1)
  if [ "$host_ip" != "127.0.0.1" ] && [ "$host_ip" != "localhost" ]; then
    echo "  CPU Usage: $(ssh "$host_ip" "top -bn1 | grep 'Cpu(s)' | awk '{print \$2}'" 2>/dev/null || echo "N/A")"
    echo "  CPU Average (5s): $(ssh "$host_ip" "vmstat 1 5 | tail -1 | awk '{print 100-\$15\"%\"}'" 2>/dev/null || echo "N/A")"
    echo "  Load Average: $(ssh "$host_ip" "uptime | awk -F'load average:' '{print \$2}'" 2>/dev/null || echo "N/A")"
    echo "  Memory Usage: $(ssh "$host_ip" "free | grep Mem | awk '{printf \"%.1f%%\", \$3/\$2 * 100}'" 2>/dev/null || echo "N/A")"
    echo "  Disk I/O: $(ssh "$host_ip" "iostat -x 1 1 2>/dev/null | tail -n +4 | awk 'NR>3 {print \$1 \": \" \$10 \"% util\"}' | head -3" 2>/dev/null || echo "iostat not available")"
  else
    echo "  CPU Usage: $(top -bn1 | grep 'Cpu(s)' | awk '{print $2}' 2>/dev/null || echo "N/A")"
    echo "  CPU Average (5s): $(vmstat 1 5 | tail -1 | awk '{print 100-$15"%"}' 2>/dev/null || echo "N/A")"
    echo "  Load Average: $(uptime | awk -F'load average:' '{print $2}' 2>/dev/null || echo "N/A")"
    echo "  Memory Usage: $(free | grep Mem | awk '{printf "%.1f%%", $3/$2 * 100}' 2>/dev/null || echo "N/A")"
  fi
}

show_cluster() {
  echo "Cluster-Wide Memory Summary:"
  curl -s "http://$HOST/_cluster/stats?pretty" | jq '.nodes.jvm.mem'
  echo
  
  echo "Cluster-Wide Max Values & Usage:"
  # Get heap stats
  heap_data=$(curl -s "http://$HOST/_nodes/stats/jvm?pretty" | jq -r '.nodes | to_entries[] | "\(.value.jvm.mem.heap_used_percent) \(.value.jvm.mem.heap_used_in_bytes) \(.value.jvm.mem.heap_max_in_bytes)"')
  
  # Calculate heap maximums
  max_heap_percent=$(echo "$heap_data" | awk '{if($1>max) max=$1} END {print max}')
  total_heap_used=$(echo "$heap_data" | awk '{sum+=$2} END {print sum}')
  total_heap_max=$(echo "$heap_data" | awk '{sum+=$3} END {print sum}')
  cluster_heap_percent=$(echo "$total_heap_used $total_heap_max" | awk '{if($2>0) printf "%.1f", ($1/$2)*100; else print "0.0"}')
  
  echo "  Max Heap Usage: ${max_heap_percent}% (highest node)"
  echo "  Cluster Heap Usage: ${cluster_heap_percent}% ($(echo "$total_heap_used" | awk '{printf "%.1fGB", $1/1073741824}') / $(echo "$total_heap_max" | awk '{printf "%.1fGB", $1/1073741824}'))"
  
  # Circuit breaker info
  echo
  echo "Circuit Breaker Configuration:"
  printf "%-25s %s\n" "Setting" "Limit"
  printf "%-25s %s\n" "-------" "-----"
  printf "%-25s %s\n" "indices.breaker.total" "70%"
  printf "%-25s %s\n" "indices.breaker.request" "60%"
  printf "%-25s %s\n" "indices.breaker.fielddata" "40%"

  echo
  echo "Circuit Breaker Usage:"
  printf "%-15s %-12s %-12s %s\n" "Breaker" "Used" "Limit" "Usage%"
  printf "%-15s %-12s %-12s %s\n" "-------" "----" "-----" "------"
  
  curl -s "http://$HOST/_nodes/stats/breaker?pretty" | jq -r '.nodes | to_entries[0] | .value.breakers | to_entries[] | select(.key | test("request|fielddata|in_flight_requests")) | [.key, .value.estimated_size, .value.limit_size, .value.estimated_size_in_bytes, .value.limit_size_in_bytes] | @tsv' 2>/dev/null | while IFS=$'\t' read breaker used limit used_bytes limit_bytes; do
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
  printf "%-35s %-8s %-8s %-8s %-10s %-10s\n" "Pool" "Active" "Queue" "Rejected" "Completed" "Largest"
  printf "%-35s %-8s %-8s %-8s %-10s %-10s\n" "----" "------" "-----" "--------" "---------" "-------"
  
  curl -s "http://$HOST/_nodes/stats/thread_pool?pretty" | jq -r '.nodes | to_entries[0] | .value.thread_pool | to_entries[] | [.key, .value.active, .value.queue, .value.rejected, .value.completed, .value.largest] | @tsv' 2>/dev/null | while IFS=$'\t' read pool active queue rejected completed largest; do
    printf "%-35s %-8s %-8s %-8s %-10s %-10s\n" "$pool" "$active" "$queue" "$rejected" "$completed" "$largest"
  done

  # Indexing Performance Metrics
  echo
  echo "Indexing Performance Metrics:"
  indexing_stats=$(curl -s "http://$HOST/_nodes/stats/indices?pretty" | jq '.nodes | to_entries[0] | .value.indices.indexing')
  echo "  Index Rate: $(echo "$indexing_stats" | jq -r '.index_total // 0') total docs, $(echo "$indexing_stats" | jq -r '.index_current // 0') current"
  echo "  Index Time: $(echo "$indexing_stats" | jq -r '.index_time_in_millis // 0')ms total"
  echo "  Throttle Time: $(echo "$indexing_stats" | jq -r '.throttle_time_in_millis // 0')ms"
  
  # Merge Activity
  merge_stats=$(curl -s "http://$HOST/_nodes/stats/indices?pretty" | jq '.nodes | to_entries[0] | .value.indices.merges')
  echo "  Active Merges: $(echo "$merge_stats" | jq -r '.current // 0')"
  echo "  Merge Throttle: $(echo "$merge_stats" | jq -r '.total_throttled_time_in_millis // 0')ms"

  # System Resource Usage
  echo
  echo "System Resource Usage:"
  host_ip=$(echo "$HOST" | cut -d: -f1)
  if [ "$host_ip" != "127.0.0.1" ] && [ "$host_ip" != "localhost" ]; then
    echo "  Disk I/O: $(ssh "$host_ip" "iostat -x 1 1 2>/dev/null | tail -n +4 | awk 'NR>3 {print \$1 \": \" \$10 \"% util\"}' | head -3" 2>/dev/null || echo "iostat not available")"
  else
    echo "  Disk I/O: Local monitoring only"
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
  echo
  echo "4. CPU and System Stats:"
  show_cpu
}

# Main execution
if [ -t 0 ]; then
  show_menu
  case $choice in
    1) chart_func="show_simple" ;;
    2) chart_func="show_detailed" ;;
    3) chart_func="show_cluster" ;;
    4) chart_func="show_cpu" ;;
    *) chart_func="show_all" ;;
  esac
else
  read choice
  case $choice in
    1) chart_func="show_simple" ;;
    2) chart_func="show_detailed" ;;
    3) chart_func="show_cluster" ;;
    4) chart_func="show_cpu" ;;
    *) chart_func="show_all" ;;
  esac
fi

while true; do
  clear
  echo "=== OpenSearch Heap Usage Stats for $HOST ($(date)) ==="
  echo
  
  $chart_func
  
  echo
  echo "Press Ctrl+C to exit. Refreshing in 1 second..."
  sleep 1
done
