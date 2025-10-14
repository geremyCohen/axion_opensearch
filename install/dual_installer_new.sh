#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 <action> [node_count] [shard_count] [heap_percent]
  
Actions:
  create    Create new OpenSearch cluster
  read      Display current cluster configuration
  update    Update existing cluster configuration  
  delete    Remove all nodes from cluster
  
Parameters (for create/update only):
  node_count    Number of nodes (default: 2)
  shard_count   Number of primary shards for nyc_taxis index (default: node_count)
  heap_percent  JVM heap memory percentage (default: 80)

Environment Variables:
  IP           Remote host IP (optional, defaults to localhost)

Examples:
  $0 create                        # Create 2-node cluster locally
  $0 create 4                      # Create 4-node cluster with 4 shards, 80% heap
  $0 create 8 16 90                # Create 8-node cluster with 16 shards, 90% heap
  IP="10.0.0.205" $0 create 4      # Create 4-node cluster on remote host
  $0 update 6                      # Scale to 6 nodes, keep existing shard/heap settings
  $0 update 0 24                   # Update to 24 shards, keep existing node/heap settings
  $0 update 0 0 85                 # Update heap to 85%, keep existing node/shard settings
  $0 read                          # Show current configuration
  $0 delete                        # Remove all cluster nodes
  IP="10.0.0.205" $0 delete        # Remove cluster from remote host
USAGE
}

# =========================
# Parameters
# =========================
ACTION="${1:-}"
NODE_COUNT="${2:-0}"
SHARD_COUNT="${3:-0}"
HEAP_PERCENT="${4:-0}"

# Validate action
if [[ ! "$ACTION" =~ ^(create|read|update|delete)$ ]]; then
    echo "ERROR: Invalid action '$ACTION'"
    usage
    exit 1
fi

# Remote execution detection
REMOTE_HOST_IP="${IP:-}"
if [[ -n "$REMOTE_HOST_IP" ]]; then
    echo "[install] Remote execution detected for $REMOTE_HOST_IP"
    echo "[install] Copying installer to remote host..."
    scp "$0" "$REMOTE_HOST_IP:/tmp/"
    echo "[install] Executing remotely: sudo /tmp/$(basename "$0") $*"
    ssh "$REMOTE_HOST_IP" "sudo /tmp/$(basename "$0") $*"
    exit $?
fi

# Log function
log() {
    echo -e "\033[1;32m[install]\033[0m $*"
}

# Main CRUD operations
case "$ACTION" in
  create)
    log "Creating $NODE_COUNT-node cluster..."
    # Call original installer logic here
    ;;
    
  read)
    log "=== Current Cluster Configuration ==="
    
    # Get node count
    actual_nodes=$(timeout 10 curl -s "http://127.0.0.1:9200/_cat/nodes?h=name" 2>/dev/null | wc -l || echo "0")
    log "Nodes: $actual_nodes"
    
    # Get shard count for nyc_taxis
    actual_shards=$(timeout 10 curl -s "http://127.0.0.1:9200/_cat/shards/nyc_taxis?h=shard,prirep" 2>/dev/null | grep "p" | wc -l || echo "0")
    log "NYC Taxis Primary Shards: $actual_shards"
    
    # Get heap settings (from first node)
    if [[ -f "/opt/opensearch-node1/config/jvm.options" ]]; then
      heap_max=$(grep "^-Xmx" /opt/opensearch-node1/config/jvm.options | sed 's/-Xmx//')
      log "Heap Size: $heap_max"
    fi
    
    # Get cluster health
    health=$(timeout 10 curl -s "http://127.0.0.1:9200/_cluster/health" 2>/dev/null | jq -r '.status' || echo "unknown")
    log "Health: $health"
    ;;
    
  update)
    log "Updating cluster configuration..."
    # Call original update logic here
    ;;
    
  delete)
    log "Deleting all cluster nodes..."
    # Call original remove logic here
    ;;
esac
