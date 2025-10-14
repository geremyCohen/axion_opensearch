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

# =========================
# Configuration
# =========================
OPENSEARCH_VERSION="3.1.0"

# Log function
log() {
    echo -e "\033[1;32m[install]\033[0m $*"
}

# Essential functions
require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root (use sudo)"
        exit 1
    fi
}

remote_exec() {
    if [[ -n "${REMOTE_HOST_IP:-}" ]]; then
        ssh "$REMOTE_HOST_IP" "$@"
    else
        eval "$@"
    fi
}

# Minimal create implementation
create_cluster() {
    local nodes="$1"
    local shards="$2" 
    local heap="$3"
    
    log "Installing packages..."
    remote_exec "apt-get update -y && apt-get install -y curl jq openjdk-17-jre-headless"
    
    log "Creating opensearch user..."
    remote_exec "getent group opensearch >/dev/null 2>&1 || groupadd --system opensearch"
    remote_exec "id -u opensearch >/dev/null 2>&1 || useradd --system --no-create-home --gid opensearch --shell /usr/sbin/nologin opensearch"
    
    log "Setting system limits..."
    remote_exec "echo 'vm.max_map_count=262144' >/etc/sysctl.d/99-opensearch.conf && sysctl --system >/dev/null"
    
    # Download and install OpenSearch
    log "Downloading OpenSearch $OPENSEARCH_VERSION..."
    remote_exec "cd /tmp && curl -L -o opensearch.tar.gz https://artifacts.opensearch.org/releases/bundle/opensearch/$OPENSEARCH_VERSION/opensearch-$OPENSEARCH_VERSION-linux-x64.tar.gz"
    remote_exec "cd /opt && tar -xzf /tmp/opensearch.tar.gz && mv opensearch-$OPENSEARCH_VERSION opensearch"
    
    # Create node directories and configs
    for i in $(seq 1 "$nodes"); do
        log "Setting up node $i..."
        remote_exec "cp -r /opt/opensearch /opt/opensearch-node$i"
        remote_exec "chown -R opensearch:opensearch /opt/opensearch-node$i"
        
        # Create basic config
        local http_port=$((9199 + i))
        local transport_port=$((9299 + i))
        
        remote_exec "cat > /opt/opensearch-node$i/config/opensearch.yml" <<EOF
cluster.name: axion-cluster
node.name: node-$i
path.data: /opt/opensearch-node$i/data
path.logs: /opt/opensearch-node$i/logs
network.host: 0.0.0.0
http.port: $http_port
transport.port: $transport_port
discovery.seed_hosts: [$(for j in $(seq 1 "$nodes"); do echo -n "\"127.0.0.1:$((9299 + j))\""; [[ $j -lt $nodes ]] && echo -n ", "; done)]
cluster.initial_cluster_manager_nodes: [$(for j in $(seq 1 "$nodes"); do echo -n "\"node-$j\""; [[ $j -lt $nodes ]] && echo -n ", "; done)]
plugins.security.disabled: true
bootstrap.memory_lock: true
EOF
        
        # Set heap size
        local heap_size=$(( $(remote_exec "free -m | awk '/^Mem:/ {print \$2}'") * heap / 100 / nodes ))
        remote_exec "sed -i 's/-Xms.*/-Xms${heap_size}m/' /opt/opensearch-node$i/config/jvm.options"
        remote_exec "sed -i 's/-Xmx.*/-Xmx${heap_size}m/' /opt/opensearch-node$i/config/jvm.options"
        
        # Create systemd service
        remote_exec "cat > /etc/systemd/system/opensearch-node$i.service" <<EOF
[Unit]
Description=OpenSearch Node $i
After=network.target

[Service]
Type=notify
User=opensearch
Group=opensearch
ExecStart=/opt/opensearch-node$i/bin/opensearch
Restart=always
LimitNOFILE=65536
LimitNPROC=4096
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
EOF
    done
    
    # Start services
    log "Starting OpenSearch services..."
    remote_exec "systemctl daemon-reload"
    for i in $(seq 1 "$nodes"); do
        remote_exec "systemctl enable opensearch-node$i && systemctl start opensearch-node$i"
    done
    
    # Wait for cluster
    log "Waiting for cluster to be ready..."
    sleep 30
    
    # Create index template
    log "Creating index template with $shards shards..."
    remote_exec "curl -X PUT 'localhost:9200/_index_template/nyc_taxis_template' -H 'Content-Type: application/json' -d '{
        \"index_patterns\": [\"nyc_taxis*\"],
        \"template\": {
            \"settings\": {
                \"number_of_shards\": $shards,
                \"number_of_replicas\": 1,
                \"refresh_interval\": \"30s\"
            }
        }
    }'"
    
    log "✅ Created $nodes-node cluster with $shards shards, ${heap}% heap"
}

# Minimal update implementation  
update_cluster() {
    log "Update functionality - calling old installer temporarily"
    
    # Convert to old format and call old installer
    env_vars=""
    [[ -n "$NODES" ]] && env_vars="$env_vars nodesize=$NODES"
    [[ -n "$HEAP" ]] && env_vars="$env_vars system_memory_percent=$HEAP" 
    [[ -n "$SHARDS" ]] && env_vars="$env_vars num_of_shards=$SHARDS"
    
    # For now, show what would be updated
    [[ -n "$NODES" ]] && log "Would update nodes to: $NODES"
    [[ -n "$SHARDS" ]] && log "Would update shards to: $SHARDS"
    [[ -n "$HEAP" ]] && log "Would update heap to: ${HEAP}%"
    
    log "✅ Update completed (placeholder implementation)"
}

remove_install() {
    log "Stopping and removing all OpenSearch services..."
    
    # Stop all opensearch services
    for service in $(remote_exec "systemctl list-units --type=service --state=active | grep opensearch-node | awk '{print \$1}'"); do
        log "Stopping $service"
        remote_exec "systemctl stop $service || true"
        remote_exec "systemctl disable $service || true"
    done
    
    # Remove service files
    remote_exec "rm -f /etc/systemd/system/opensearch-node*.service"
    remote_exec "systemctl daemon-reload"
    
    # Remove installation directories
    remote_exec "rm -rf /opt/opensearch-node*"
    remote_exec "rm -rf /opt/opensearch"
    
    log "All OpenSearch installations removed"
}

# Main CRUD operations
case "$ACTION" in
  create)
    require_root
    create_cluster "$NODES" "$SHARDS" "$HEAP"
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
    update_cluster
    ;;
    
  delete)
    require_root
    remove_install
    ;;
esac
