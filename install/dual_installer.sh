#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 <action> [options]
  
Actions:
  create    Create new OpenSearch cluster (all options required)
  read      Display current cluster configuration (no options)
  update    Update existing cluster configuration (one or more options required)
  delete    Remove all nodes from cluster (no options)
  
Options:
  --nodes N         Number of nodes
  --shards N        Number of primary shards for nyc_taxis index  
  --heap N          JVM heap memory percentage (1-100)

Environment Variables:
  IP               Remote host IP (optional, defaults to localhost)

Examples:
  $0 create --nodes 4 --shards 8 --heap 90    # Create 4-node cluster
  $0 update --nodes 6                         # Scale to 6 nodes
  $0 update --shards 24                       # Update to 24 shards
  $0 update --heap 85                         # Update heap to 85%
  $0 update --nodes 8 --shards 16 --heap 90   # Update multiple settings
  $0 read                                      # Show current configuration
  $0 delete                                    # Remove all cluster nodes
  IP="10.0.0.205" $0 create --nodes 4 --shards 4 --heap 80
USAGE
}

# =========================
# Parse arguments
# =========================
ACTION="${1:-}"
shift || true

NODES=""
SHARDS=""
HEAP=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --nodes)
      NODES="$2"
      shift 2
      ;;
    --shards)
      SHARDS="$2"
      shift 2
      ;;
    --heap)
      HEAP="$2"
      shift 2
      ;;
    *)
      echo "ERROR: Unknown option $1"
      usage
      exit 1
      ;;
  esac
done

# Validate action
if [[ ! "$ACTION" =~ ^(create|read|update|delete)$ ]]; then
    echo "ERROR: Invalid action '$ACTION'"
    usage
    exit 1
fi

# Validate required parameters for create
if [[ "$ACTION" == "create" ]]; then
    if [[ -z "$NODES" || -z "$SHARDS" || -z "$HEAP" ]]; then
        echo "ERROR: create requires --nodes, --shards, and --heap"
        usage
        exit 1
    fi
fi

# Validate at least one parameter for update
if [[ "$ACTION" == "update" ]]; then
    if [[ -z "$NODES" && -z "$SHARDS" && -z "$HEAP" ]]; then
        echo "ERROR: update requires at least one of --nodes, --shards, or --heap"
        usage
        exit 1
    fi
fi

# Remote execution detection
REMOTE_HOST_IP="${IP:-}"
if [[ -n "$REMOTE_HOST_IP" ]]; then
    echo "[install] Remote execution detected for $REMOTE_HOST_IP"
    echo "[install] Copying installer to remote host..."
    scp "$0" "$REMOTE_HOST_IP:/tmp/"
    echo "[install] Executing remotely: sudo /tmp/$(basename "$0") $*"
    ssh "$REMOTE_HOST_IP" "sudo /tmp/$(basename "$0") $ACTION $([ -n "$NODES" ] && echo "--nodes $NODES") $([ -n "$SHARDS" ] && echo "--shards $SHARDS") $([ -n "$HEAP" ] && echo "--heap $HEAP")"
    exit $?
fi

# Log function
log() {
    echo -e "\033[1;32m[install]\033[0m $*"
}

# Essential functions from old installer
require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root (use sudo)"
        exit 1
    fi
}

remove_install() {
    log "Stopping and removing all OpenSearch services..."
    
    # Stop all opensearch services
    for service in $(systemctl list-units --type=service --state=active | grep opensearch-node | awk '{print $1}'); do
        log "Stopping $service"
        systemctl stop "$service" || true
        systemctl disable "$service" || true
    done
    
    # Remove service files
    rm -f /etc/systemd/system/opensearch-node*.service
    systemctl daemon-reload
    
    # Remove installation directories
    rm -rf /opt/opensearch-node*
    rm -rf /opt/opensearch
    
    log "All OpenSearch installations removed"
}

# Main CRUD operations
case "$ACTION" in
  create)
    require_root
    log "Creating $NODES-node cluster with $SHARDS shards, ${HEAP}% heap..."
    log "ERROR: Create function not fully implemented yet - requires porting install logic"
    exit 1
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
    require_root
    log "Updating cluster configuration..."
    [[ -n "$NODES" ]] && log "  Nodes: $NODES"
    [[ -n "$SHARDS" ]] && log "  Shards: $SHARDS" 
    [[ -n "$HEAP" ]] && log "  Heap: ${HEAP}%"
    log "ERROR: Update function not fully implemented yet - requires porting update logic"
    exit 1
    ;;
    
  delete)
    require_root
    remove_install
    ;;
esac
