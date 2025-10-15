#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 <action> [options]
  
Actions:
  create       Create new OpenSearch cluster (all options required)
  read         Display current cluster configuration (no options)
  update       Update existing cluster configuration (one or more options required)
  delete       Remove all nodes from cluster (no options)
  drop         Drop all data except index templates (no options)
  drop_all     Drop all data including templates, aliases, pipelines (no options)
  osb_command  Generate OpenSearch Benchmark command (optional parameters)
  
Options:
  --nodes N         Number of nodes
  --shards N        Number of primary shards for nyc_taxis index  
  --heap N          JVM heap memory percentage (1-100)
  --workload NAME   Workload name for OSB (default: nyc_taxis)
  --include-tasks T Include tasks parameter for OSB (optional)
  --clients N       Number of bulk indexing clients (default: 20)
  --osb-shards N    Number of shards for OSB workload-params (default: 8)

Environment Variables:
  IP               Remote host IP (optional, defaults to localhost)

Examples:
  $0 create --nodes 4 --shards 8 --heap 90    # Create 4-node cluster
  $0 update --nodes 6                         # Scale to 6 nodes
  $0 update --shards 16                       # Update to 16 shards
  $0 update --shards 24                       # Update to 24 shards
  $0 update --heap 85                         # Update heap to 85%
  $0 update --nodes 8 --shards 16 --heap 90   # Update multiple settings
  
  # Complete benchmark workflow:
  $0 update --shards 16                       # Set index template to 16 shards
  $0 drop                                      # Clear all data, keep templates
  # Then run the OSB command from 'read' output
  $0 read                                      # Show current configuration
  $0 delete                                    # Remove all cluster nodes
  $0 drop                                      # Drop all data, keep templates
  $0 drop_all                                  # Drop everything (data + templates)
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
WORKLOAD=""
INCLUDE_TASKS=""
CLIENTS=""
OSB_SHARDS=""

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
    --workload)
      WORKLOAD="$2"
      shift 2
      ;;
    --include-tasks)
      INCLUDE_TASKS="$2"
      shift 2
      ;;
    --clients)
      CLIENTS="$2"
      shift 2
      ;;
    --osb-shards)
      OSB_SHARDS="$2"
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
if [[ ! "$ACTION" =~ ^(create|read|update|delete|drop|drop_all|osb_command)$ ]]; then
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
    echo "[install] Remote execution detected for $REMOTE_HOST_IP" >&2
    echo "[install] Copying installer to remote host..." >&2
    scp "$0" "$REMOTE_HOST_IP:/tmp/"
    echo "[install] Executing remotely: sudo /tmp/$(basename "$0") $*" >&2
    ssh "$REMOTE_HOST_IP" "sudo /tmp/$(basename "$0") $ACTION $([ -n "$NODES" ] && echo "--nodes $NODES") $([ -n "$SHARDS" ] && echo "--shards $SHARDS") $([ -n "$HEAP" ] && echo "--heap $HEAP") $([ -n "$WORKLOAD" ] && echo "--workload $WORKLOAD") $([ -n "$INCLUDE_TASKS" ] && echo "--include-tasks $INCLUDE_TASKS") $([ -n "$CLIENTS" ] && echo "--clients $CLIENTS") $([ -n "$OSB_SHARDS" ] && echo "--osb-shards $OSB_SHARDS")"
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

# Memory monitoring for async operations
check_memory_and_sleep() {
    local available_mb=$(remote_exec "free -m | awk '/^Mem:/ {print \$7}'")
    local total_mb=$(remote_exec "free -m | awk '/^Mem:/ {print \$2}'")
    local available_percent=$(( available_mb * 100 / total_mb ))
    
    if [[ $available_percent -le 10 ]]; then
        log "FATAL: Available memory critically low: ${available_percent}% (${available_mb}MB/${total_mb}MB)"
        log "Aborting operation to prevent system instability"
        exit 1
    fi
    
    sleep 1.0
}

# Calculate heap size with safety limits
calculate_heap_size() {
    local heap_percent="$1"
    local node_count="$2"
    
    local total_memory_mb=$(remote_exec "free -m | awk '/^Mem:/ {print \$2}'")
    local target_heap_mb
    
    # Set to 8GB if node_count is 0, otherwise calculate normally
    if [[ "$node_count" -eq 0 ]]; then
        target_heap_mb=8192  # 8GB in MB
    else
        target_heap_mb=$(( total_memory_mb * heap_percent / 100 / node_count ))
    fi
    local max_heap_mb=8192  # 8GB in MB
    
    # Never exceed 31GB per node
    if [[ $target_heap_mb -gt $max_heap_mb ]]; then
        target_heap_mb=$max_heap_mb
    fi
    
    # Never exceed 80% of system memory total (safety check)
    local max_system_heap_mb=$(( total_memory_mb * 80 / 100 / node_count ))
    if [[ $target_heap_mb -gt $max_system_heap_mb ]]; then
        target_heap_mb=$max_system_heap_mb
    fi
    
    echo "$target_heap_mb"
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
    remote_exec "apt-get update -y && apt-get install -y curl jq openjdk-21-jre-headless"
    
    log "Creating opensearch user..."
    remote_exec "getent group opensearch >/dev/null 2>&1 || groupadd --system opensearch"
    remote_exec "id -u opensearch >/dev/null 2>&1 || useradd --system --no-create-home --gid opensearch --shell /usr/sbin/nologin opensearch"
    
    log "Setting system limits..."
    remote_exec "echo 'vm.max_map_count=262144' >/etc/sysctl.d/99-opensearch.conf && sysctl --system >/dev/null"
    
    # Set user limits for opensearch user
    remote_exec "cat > /etc/security/limits.d/99-opensearch.conf" <<EOF
opensearch soft nofile 65536
opensearch hard nofile 65536
opensearch soft nproc 65536
opensearch hard nproc 65536
opensearch soft memlock unlimited
opensearch hard memlock unlimited
EOF
    
    # Download and install OpenSearch
    log "Downloading OpenSearch $OPENSEARCH_VERSION..."
    remote_exec "cd /tmp && curl -L -o opensearch.tar.gz https://artifacts.opensearch.org/releases/bundle/opensearch/$OPENSEARCH_VERSION/opensearch-$OPENSEARCH_VERSION-linux-x64.tar.gz"
    remote_exec "cd /opt && tar -xzf /tmp/opensearch.tar.gz && mv opensearch-$OPENSEARCH_VERSION opensearch"
    
    # Create node directories and configs
    for i in $(seq 1 "$nodes"); do
        log "Setting up node $i..."
        remote_exec "cp -r /opt/opensearch /opt/opensearch-node$i"
        remote_exec "mkdir -p /opt/opensearch-node$i/data /opt/opensearch-node$i/logs"
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
        local heap_size=$(calculate_heap_size "$heap" "$nodes")
        remote_exec "sed -i 's/-Xms.*/-Xms${heap_size}m/' /opt/opensearch-node$i/config/jvm.options"
        remote_exec "sed -i 's/-Xmx.*/-Xmx${heap_size}m/' /opt/opensearch-node$i/config/jvm.options"
        
        # Create systemd service
        remote_exec "cat > /etc/systemd/system/opensearch-node$i.service" <<EOF
[Unit]
Description=OpenSearch Node $i
After=network.target

[Service]
Type=simple
User=opensearch
Group=opensearch
ExecStart=/opt/opensearch-node$i/bin/opensearch
Restart=always
RestartSec=10
LimitNOFILE=65536
LimitNPROC=65536
LimitMEMLOCK=infinity
Environment=OPENSEARCH_JAVA_HOME=/usr/lib/jvm/java-21-openjdk-arm64
Environment=OPENSEARCH_PATH_CONF=/opt/opensearch-node$i/config
WorkingDirectory=/opt/opensearch-node$i

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
    for attempt in {1..30}; do
        if remote_exec "curl -s localhost:9200/_cluster/health >/dev/null 2>&1"; then
            log "Cluster is ready!"
            break
        fi
        log "Waiting for cluster... (attempt $attempt/30)"
        sleep 10
    done
    
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
    local current_nodes=$(remote_exec "ls -d /opt/opensearch-node* 2>/dev/null | wc -l")
    
    # Update heap if specified
    if [[ -n "$HEAP" ]]; then
        log "Updating heap to ${HEAP}%..."
        local heap_size=$(calculate_heap_size "$HEAP" "$current_nodes")
        
        # Stop all services first
        for i in $(seq 1 "$current_nodes"); do
            remote_exec "systemctl stop opensearch-node$i"
        done
        
        # Update heap settings
        for i in $(seq 1 "$current_nodes"); do
            remote_exec "sed -i 's/-Xms.*/-Xms${heap_size}m/' /opt/opensearch-node$i/config/jvm.options"
            remote_exec "sed -i 's/-Xmx.*/-Xmx${heap_size}m/' /opt/opensearch-node$i/config/jvm.options"
        done
        
        # Start all services
        for i in $(seq 1 "$current_nodes"); do
            remote_exec "systemctl start opensearch-node$i"
            sleep 5  # Stagger startup
        done
        
        # Wait for cluster to recover
        log "Waiting for cluster recovery after heap update..."
        for attempt in {1..20}; do
            if remote_exec "curl -s localhost:9200/_cluster/health >/dev/null 2>&1"; then
                log "Cluster recovered!"
                break
            fi
            log "Waiting for cluster recovery... (attempt $attempt/20)"
            sleep 15
        done
    fi
    
    # Scale nodes if specified
    if [[ -n "$NODES" && "$NODES" -ne "$current_nodes" ]]; then
        if [[ "$NODES" -gt "$current_nodes" ]]; then
            # Add nodes
            log "Scaling up from $current_nodes to $NODES nodes..."
            for i in $(seq $((current_nodes + 1)) "$NODES"); do
                log "Adding node $i..."
                remote_exec "cp -r /opt/opensearch /opt/opensearch-node$i"
                remote_exec "mkdir -p /opt/opensearch-node$i/data /opt/opensearch-node$i/logs"
                remote_exec "chown -R opensearch:opensearch /opt/opensearch-node$i"
                
                # Create config
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
discovery.seed_hosts: [$(for j in $(seq 1 "$NODES"); do echo -n "\"127.0.0.1:$((9299 + j))\""; [[ $j -lt $NODES ]] && echo -n ", "; done)]
cluster.initial_cluster_manager_nodes: [$(for j in $(seq 1 "$NODES"); do echo -n "\"node-$j\""; [[ $j -lt $NODES ]] && echo -n ", "; done)]
plugins.security.disabled: true
bootstrap.memory_lock: true
EOF
                
                # Set default 8GB heap for new nodes
                remote_exec "sed -i 's/-Xms.*/-Xms8192m/' /opt/opensearch-node$i/config/jvm.options"
                remote_exec "sed -i 's/-Xmx.*/-Xmx8192m/' /opt/opensearch-node$i/config/jvm.options"
                
                # Create service
                remote_exec "cat > /etc/systemd/system/opensearch-node$i.service" <<EOF
[Unit]
Description=OpenSearch Node $i
After=network.target

[Service]
Type=simple
User=opensearch
Group=opensearch
ExecStart=/opt/opensearch-node$i/bin/opensearch
Restart=always
RestartSec=10
LimitNOFILE=65536
LimitNPROC=65536
LimitMEMLOCK=infinity
Environment=OPENSEARCH_JAVA_HOME=/usr/lib/jvm/java-21-openjdk-arm64
Environment=OPENSEARCH_PATH_CONF=/opt/opensearch-node$i/config
WorkingDirectory=/opt/opensearch-node$i

[Install]
WantedBy=multi-user.target
EOF
                
                remote_exec "systemctl daemon-reload"
                remote_exec "systemctl enable opensearch-node$i && systemctl start opensearch-node$i"
            done
        else
            # Remove nodes
            log "Scaling down from $current_nodes to $NODES nodes..."
            
            # First, update remaining nodes' configurations before removing nodes
            log "Updating remaining nodes' configurations..."
            for i in $(seq 1 "$NODES"); do
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
discovery.seed_hosts: [$(for j in $(seq 1 "$NODES"); do echo -n "\"127.0.0.1:$((9299 + j))\""; [[ $j -lt $NODES ]] && echo -n ", "; done)]
cluster.initial_cluster_manager_nodes: [$(for j in $(seq 1 "$NODES"); do echo -n "\"node-$j\""; [[ $j -lt $NODES ]] && echo -n ", "; done)]
plugins.security.disabled: true
bootstrap.memory_lock: true
EOF
            done
            
            # Then remove the excess nodes
            for i in $(seq $((NODES + 1)) "$current_nodes"); do
                log "Removing node $i..."
                remote_exec "systemctl stop opensearch-node$i || true"
                remote_exec "systemctl disable opensearch-node$i || true"
                remote_exec "rm -f /etc/systemd/system/opensearch-node$i.service"
                remote_exec "rm -rf /opt/opensearch-node$i"
            done
            remote_exec "systemctl daemon-reload"
        fi
        
        # Monitor cluster stabilization with memory checks every 1s
        if [[ "$NODES" -gt 0 ]]; then
            log "Monitoring cluster stabilization with memory checks..."
            for attempt in {1..60}; do
                check_memory_and_sleep
                
                local current_node_count=$(remote_exec "curl -s localhost:9200/_cat/nodes?h=name 2>/dev/null | wc -l" | tr -d '\n' || echo "0")
                local cluster_status=$(remote_exec "curl -s localhost:9200/_cluster/health 2>/dev/null | jq -r '.status // \"unknown\"' 2>/dev/null" | tr -d '\n' || echo "unknown")
                
                if [[ "$current_node_count" -eq "$NODES" && "$cluster_status" == "green" ]]; then
                    log "Cluster stabilized: $current_node_count nodes, status: $cluster_status"
                    break
                fi
                log "Waiting for cluster stabilization... (attempt $attempt/60, nodes: $current_node_count/$NODES, status: $cluster_status)"
            done
        else
            log "Scaled to 0 nodes - no cluster to monitor"
        fi
    fi
    
    # Update shards if specified
    if [[ -n "$SHARDS" ]]; then
        log "Updating nyc_taxis index to $SHARDS shards..."
        
        # Start async operations
        log "Starting async shard operations..."
        remote_exec "curl -X DELETE 'localhost:9200/nyc_taxis*' >/dev/null 2>&1 &"
        remote_exec "curl -X PUT 'localhost:9200/_index_template/nyc_taxis_template' -H 'Content-Type: application/json' -d '{
            \"index_patterns\": [\"nyc_taxis*\"],
            \"template\": {
                \"settings\": {
                    \"number_of_shards\": $SHARDS,
                    \"number_of_replicas\": 1,
                    \"refresh_interval\": \"30s\"
                }
            }
        }' >/dev/null 2>&1 &"
        
        # Monitor with memory checks every 1s
        log "Monitoring template update with memory checks..."
        for attempt in {1..30}; do
            check_memory_and_sleep
            
            local current_shards=$(remote_exec "curl -s 'localhost:9200/_index_template/nyc_taxis_template' 2>/dev/null | jq -r '.index_templates[0].index_template.template.settings.index.number_of_shards // \"0\"' 2>/dev/null || echo '0'")
            if [[ "$current_shards" == "$SHARDS" ]]; then
                log "Template updated successfully to $SHARDS shards"
                break
            fi
            log "Waiting for template update... (attempt $attempt/30, current: $current_shards, target: $SHARDS)"
        done
    fi
    
    log "✅ Update completed"
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

# =========================
# Generate OSB Command
# =========================
generate_osb_command() {
    local workload="${1:-nyc_taxis}"
    local include_tasks="$2"
    local clients="${3:-20}"
    local osb_shards="${4:-8}"
    
    # Get node count (use remote_exec if in remote context, otherwise direct curl)
    local node_response
    if [[ -n "${REMOTE_HOST_IP:-}" ]]; then
        node_response=$(remote_exec "timeout 10 curl -s 'localhost:9200/_cat/nodes?h=name' 2>/dev/null || echo ''")
    else
        node_response=$(timeout 10 curl -s "localhost:9200/_cat/nodes?h=name" 2>/dev/null || echo "")
    fi
    
    if [[ -z "$node_response" ]]; then
        echo "ERROR: No OpenSearch nodes found" >&2
        exit 1
    fi
    actual_nodes=$(echo "$node_response" | wc -l)
    
    # Determine host IP
    if [[ -n "${IP:-}" ]]; then
        host_ip="$IP"
    else
        host_ip=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "127.0.0.1")
    fi
    
    # Build target-hosts string
    target_hosts=""
    for ((i=1; i<=actual_nodes; i++)); do
        port=$((9199 + i))
        if [[ $i -eq 1 ]]; then
            target_hosts="${host_ip}:${port}"
        else
            target_hosts="${target_hosts},${host_ip}:${port}"
        fi
    done
    
    # Build OSB command
    local osb_cmd="opensearch-benchmark run --workload=${workload}"
    osb_cmd="${osb_cmd} --test-procedure=append-no-conflicts-index-only"
    osb_cmd="${osb_cmd} --target-hosts=${target_hosts}"
    osb_cmd="${osb_cmd} --client-options=use_ssl:false,verify_certs:false,timeout:60"
    osb_cmd="${osb_cmd} --kill-running-processes"
    
    if [[ -n "$include_tasks" ]]; then
        osb_cmd="${osb_cmd} --include-tasks=\"${include_tasks}\""
    fi
    
    osb_cmd="${osb_cmd} --workload-params=\"bulk_indexing_clients:${clients},bulk_size:10000,number_of_shards:${osb_shards}\""
    
    echo "$osb_cmd"
}

# Main CRUD operations
case "$ACTION" in
  create)
    require_root
    create_cluster "$NODES" "$SHARDS" "$HEAP"
    ;;
    
  read)
    echo "=== Current Cluster Configuration ==="
    
    # Get node count
    node_response=$(timeout 10 curl -s "localhost:9200/_cat/nodes?h=name" 2>/dev/null || echo "")
    if [[ -z "$node_response" ]]; then
        actual_nodes=0
    else
        actual_nodes=$(echo "$node_response" | wc -l)
    fi
    echo "Nodes: $actual_nodes"
    
    # Get shard count for nyc_taxis
    index_name="nyc_taxis"
    shard_response=$(timeout 10 curl -s "localhost:9200/_cat/shards/${index_name}?h=shard,prirep" 2>/dev/null || echo "")
    if [[ "$shard_response" == *"error"* ]] || [[ -z "$shard_response" ]]; then
        # No index exists, check template
        template_shards=$(timeout 10 curl -s "localhost:9200/_index_template/${index_name}_template" 2>/dev/null | jq -r '.index_templates[0].index_template.template.settings.index.number_of_shards // "0"' 2>/dev/null || echo "0")
        echo "${index_name} shards: $template_shards (template)"
    else
        actual_shards=$(echo "$shard_response" | grep "p" | wc -l)
        echo "${index_name} shards: $actual_shards (active index)"
    fi
    
    # Get heap settings (from first node)
    if [[ -f "/opt/opensearch-node1/config/jvm.options" ]]; then
      heap_mb=$(grep "^-Xmx" /opt/opensearch-node1/config/jvm.options | sed 's/-Xmx\|m//g')
      heap_gb=$(( heap_mb / 1024 ))
      echo "Heap Size: ${heap_gb}GB (${heap_mb}MB)"
    fi
    
    # Get cluster health
    health=$(timeout 10 curl -s "localhost:9200/_cluster/health" 2>/dev/null | jq -r '.status' 2>/dev/null || echo "unknown")
    echo "Health: $health"
    
    # Generate OSB connection string if nodes exist
    if [[ "$actual_nodes" -gt 0 ]]; then
        echo ""
        echo "=== OpenSearch Benchmark Command ==="
        echo "# Standard workflow:"
        echo "./dual_installer.sh update --shards 16 && \\"
        echo "./dual_installer.sh drop && \\"
        echo ""
        echo "# Hard reset workflow:"
        echo "./dual_installer.sh drop_all && \\"
        echo "./dual_installer.sh update --shards 16 && \\"
        echo "./dual_installer.sh drop && \\"
        
        # Determine host IP
        if [[ -n "${IP:-}" ]]; then
            host_ip="$IP"
        else
            # Get the actual IP of the current machine
            host_ip=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "127.0.0.1")
        fi
        
        # Build target-hosts string
        target_hosts=""
        for ((i=1; i<=actual_nodes; i++)); do
            port=$((9199 + i))
            if [[ $i -eq 1 ]]; then
                target_hosts="${host_ip}:${port}"
            else
                target_hosts="${target_hosts},${host_ip}:${port}"
            fi
        done
        
        # Calculate bulk_indexing_clients (nodes * 4 + 20, capped at 150)
        bulk_clients=$((actual_nodes * 4 + 20))
        if [[ $bulk_clients -gt 150 ]]; then
            bulk_clients=150
        fi
        
        # Get shard count from template for OSB parameters
        template_shards=$(timeout 10 curl -s "localhost:9200/_index_template/${index_name}_template" 2>/dev/null | jq -r '.index_templates[0].index_template.template.settings.index.number_of_shards // "1"' 2>/dev/null || echo "1")
        
        # Output the complete command sequence
        echo "opensearch-benchmark run --workload=nyc_taxis \\"
        echo "  --test-procedure=append-no-conflicts-index-only \\"
        echo "  --target-hosts=${target_hosts} \\"
        echo "  --client-options=use_ssl:false,verify_certs:false,timeout:60 \\"
        echo "  --kill-running-processes \\"
        echo "  --workload-params=\"bulk_indexing_clients:${bulk_clients},bulk_size:10000,number_of_shards:${template_shards}\""
    fi
    ;;
    
  update)
    require_root
    update_cluster
    ;;
    
  osb_command)
    generate_osb_command "$WORKLOAD" "$INCLUDE_TASKS" "$CLIENTS" "$OSB_SHARDS"
    ;;
    
  delete)
    require_root
    remove_install
    ;;
    
  drop)
    log "Dropping all data except index templates..."
    remote_exec "curl -X DELETE 'localhost:9200/*' >/dev/null 2>&1"
    log "✅ All data dropped, index templates preserved"
    ;;
    
  drop_all)
    log "Dropping ALL data including templates, aliases, and pipelines..."
    
    # Delete all indices (including system indices)
    remote_exec "curl -X DELETE 'localhost:9200/*?expand_wildcards=all' >/dev/null 2>&1"
    
    # Delete all index templates
    remote_exec "curl -X DELETE 'localhost:9200/_index_template/*' >/dev/null 2>&1"
    
    # Delete all legacy templates
    remote_exec "curl -X DELETE 'localhost:9200/_template/*' >/dev/null 2>&1"
    
    # Delete all aliases
    remote_exec "curl -X DELETE 'localhost:9200/_alias/*' >/dev/null 2>&1"
    
    # Delete all ingest pipelines
    remote_exec "curl -X DELETE 'localhost:9200/_ingest/pipeline/*' >/dev/null 2>&1"
    
    # Delete all component templates
    remote_exec "curl -X DELETE 'localhost:9200/_component_template/*' >/dev/null 2>&1"
    
    # Delete all stored scripts
    remote_exec "curl -X DELETE 'localhost:9200/_scripts/*' >/dev/null 2>&1"
    
    log "✅ All data, templates, aliases, and pipelines dropped"
    ;;
esac
