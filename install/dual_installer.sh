#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 [install|remove|update] [node_count] [remote_ip]
  install     Install or upgrade OpenSearch cluster (default if omitted)
  remove      Stop services and remove all OpenSearch installations (auto-detects node count)
  update      Update existing cluster configuration (requires environment variables)
  node_count  Number of nodes to install (default: 2, ignored for remove/update)
  remote_ip   Remote host IP for SSH installation (optional, installs locally if omitted)

Examples:
  $0 install                    # Install 2-node cluster locally
  $0 install 4                  # Install 4-node cluster locally
  $0 install 4 10.0.0.205       # Install 4-node cluster on remote host
  $0 remove                     # Remove all nodes locally (auto-detect)
  $0 remove 10.0.0.205          # Remove all nodes from remote host (auto-detect)
  
Update examples:
  system_memory_percent=80 $0 update 10.0.0.205                    # Update heap to 80% memory split
  indices_breaker_total_limit=85% $0 update 10.0.0.205            # Update total breaker limit
  system_memory_percent=70 indices_breaker_request_limit=60% $0 update 10.0.0.205  # Multiple settings

Update environment variables:
  system_memory_percent         # Heap memory percentage (1-100)
  indices_breaker_total_limit   # Total circuit breaker limit (e.g., 85%)
  indices_breaker_request_limit # Request circuit breaker limit (e.g., 70%)
  indices_breaker_fielddata_limit # Fielddata circuit breaker limit (e.g., 50%)
USAGE
}

# =========================
# Configurable parameters
# =========================
OPENSEARCH_VERSION="${OPENSEARCH_VERSION:-2.13.0}"
ACTION="${1:-install}"

# For remove/update, node_count is ignored (auto-detected)
# For install, parse node_count and remote_ip normally
if [[ "$ACTION" == "remove" || "$ACTION" == "update" ]]; then
  NODE_COUNT=0  # Will be auto-detected
  REMOTE_IP="${2:-}"  # Second parameter is remote_ip for remove/update
else
  NODE_COUNT="${2:-2}"
  REMOTE_IP="${3:-}"
  
  # Validate node count for install
  if ! [[ "$NODE_COUNT" =~ ^[1-9][0-9]*$ ]]; then
    echo "[error] Invalid node count: $NODE_COUNT. Must be a positive integer" >&2
    exit 1
  fi
fi

# Remote execution wrapper
remote_exec() {
  if [[ -n "$REMOTE_IP" ]]; then
    # Use original username if running with sudo
    local ssh_user="${SUDO_USER:-$USER}"
    ssh "${ssh_user}@${REMOTE_IP}" "sudo $*"
  else
    eval "$@"
  fi
}

# Remote file copy wrapper
remote_copy() {
  local src="$1"
  local dest="$2"
  if [[ -n "$REMOTE_IP" ]]; then
    # Use original username if running with sudo
    local ssh_user="${SUDO_USER:-$USER}"
    scp "$src" "${ssh_user}@${REMOTE_IP}:$dest"
  else
    cp "$src" "$dest"
  fi
}

# Architecture detection for correct OpenSearch bundle
UNAME_M="$(uname -m)"
case "$UNAME_M" in
  x86_64|amd64)
    OS_BUNDLE_ARCH="linux-x64"
    ;;
  aarch64|arm64)
    OS_BUNDLE_ARCH="linux-arm64"
    ;;
  *)
    echo "[error] Unsupported architecture: $UNAME_M" >&2
    echo "        Supported: x86_64/amd64, aarch64/arm64" >&2
    exit 1
    ;;
esac

# Fixed install locations (do not change at runtime)
BASE_DIR="/opt"
BASE_DIST_DIR="${BASE_DIR}/opensearch-dist-${OPENSEARCH_VERSION}"
BASE_LINK="${BASE_DIR}/opensearch-dist"            # stable pointer to the dist

TARBALL_PATH="/tmp/opensearch-${OPENSEARCH_VERSION}-${OS_BUNDLE_ARCH}.tar.gz"

# Generate node configurations
declare -a NODE_HOMES
declare -a NODE_HTTP_PORTS
declare -a NODE_TRANSPORT_PORTS
declare -a SERVICE_NAMES

for i in $(seq 1 $NODE_COUNT); do
  NODE_HOMES[$i]="${BASE_DIR}/opensearch-node${i}"
  NODE_HTTP_PORTS[$i]=$((9199 + i))
  NODE_TRANSPORT_PORTS[$i]=$((9299 + i))
  SERVICE_NAMES[$i]="opensearch-node${i}"
done
SVC1="opensearch-node1"
SVC2="opensearch-node2"

update_heap_config() {
  local memory_percent="${system_memory_percent:-50}"
  local total_limit="${indices_breaker_total_limit:-}"
  local request_limit="${indices_breaker_request_limit:-}"
  local fielddata_limit="${indices_breaker_fielddata_limit:-}"
  
  # Validate memory percentage
  if ! [[ "$memory_percent" =~ ^[1-9][0-9]*$ ]] || [ "$memory_percent" -gt 100 ]; then
    echo "[error] Invalid system_memory_percent: $memory_percent. Must be 1-100" >&2
    exit 1
  fi
  
  # Auto-detect existing nodes
  local detected_nodes=()
  for i in {1..50}; do
    if remote_exec "[ -d \"/opt/opensearch-node${i}\" ]"; then
      detected_nodes+=($i)
    fi
  done
  
  if [ ${#detected_nodes[@]} -eq 0 ]; then
    log "No OpenSearch nodes found to update."
    return 0
  fi
  
  local node_count=${#detected_nodes[@]}
  local new_heap=$(calc_heap_gb_with_percent "$memory_percent" "$node_count")
  
  log "Updating ${node_count} nodes:"
  log "  - Heap: ${new_heap}g per node (${memory_percent}% system memory)"
  [[ -n "$total_limit" ]] && log "  - indices.breaker.total.limit: ${total_limit}"
  [[ -n "$request_limit" ]] && log "  - indices.breaker.request.limit: ${request_limit}"
  [[ -n "$fielddata_limit" ]] && log "  - indices.breaker.fielddata.limit: ${fielddata_limit}"
  
  # Stop services
  log "Stopping OpenSearch services..."
  for node in "${detected_nodes[@]}"; do
    remote_exec "systemctl stop opensearch-node${node} 2>/dev/null || true"
  done
  
  # Update configurations for each node
  for node in "${detected_nodes[@]}"; do
    log "Updating configuration for node-${node}"
    
    # Update heap configuration
    local heap_content="-Xms${new_heap}g
-Xmx${new_heap}g"
    echo "$heap_content" > "/opt/opensearch-node${node}/config/jvm.options.d/heap.options"
    
    # Update circuit breaker settings if provided
    if [[ -n "$total_limit" || -n "$request_limit" || -n "$fielddata_limit" ]]; then
      # Remove existing breaker settings first
      remote_exec "sed -i '/^indices\.breaker\./d' \"/opt/opensearch-node${node}/config/opensearch.yml\""
      
      # Append new breaker settings
      [[ -n "$total_limit" ]] && echo "indices.breaker.total.limit: ${total_limit}" >> "/opt/opensearch-node${node}/config/opensearch.yml"
      [[ -n "$request_limit" ]] && echo "indices.breaker.request.limit: ${request_limit}" >> "/opt/opensearch-node${node}/config/opensearch.yml"
      [[ -n "$fielddata_limit" ]] && echo "indices.breaker.fielddata.limit: ${fielddata_limit}" >> "/opt/opensearch-node${node}/config/opensearch.yml"
    fi
  done
  
  # Restart services
  log "Restarting OpenSearch services..."
  for node in "${detected_nodes[@]}"; do
    remote_exec "systemctl start opensearch-node${node}"
  done
  
  log "Configuration update complete. Updated ${node_count} nodes."
}

remove_install() {
  # Auto-detect existing nodes
  local detected_nodes=()
  local detected_services=()
  
  for i in {1..50}; do
    if remote_exec "[ -d \"/opt/opensearch-node${i}\" ]"; then
      detected_nodes+=($i)
      detected_services+=("opensearch-node${i}")
    fi
  done
  
  if [ ${#detected_nodes[@]} -eq 0 ]; then
    log "No OpenSearch nodes found to remove."
    return 0
  fi
  
  log "Detected ${#detected_nodes[@]} nodes to remove: ${detected_nodes[*]}"

  log "Stopping services if running..."
  set +e
  for service in "${detected_services[@]}"; do
    remote_exec "systemctl stop \"${service}\" 2>/dev/null || true"
  done
  set -e

  log "Disabling services..."
  set +e
  for service in "${detected_services[@]}"; do
    remote_exec "systemctl disable \"${service}\" 2>/dev/null || true"
  done
  set -e

  log "Removing systemd unit files..."
  for service in "${detected_services[@]}"; do
    remote_exec "rm -f \"/etc/systemd/system/${service}.service\""
  done
  remote_exec "systemctl daemon-reload || true"

  log "Removing node homes and base distribution..."
  for node in "${detected_nodes[@]}"; do
    remote_exec "rm -rf \"/opt/opensearch-node${node}\""
  done
  remote_exec "rm -rf \"${BASE_DIST_DIR}\""
  remote_exec "rm -f \"${BASE_LINK}\""

  log "Removing installer-created sysctl and limits files..."
  remote_exec "rm -f /etc/sysctl.d/99-opensearch.conf"
  remote_exec "sysctl --system >/dev/null 2>&1 || true"
  remote_exec "rm -f /etc/security/limits.d/opensearch.conf"

  # Optional: remove opensearch user/group if unused
  if remote_exec "id -u opensearch >/dev/null 2>&1"; then
    log "Removing 'opensearch' system user (if present)..."
    set +e
    remote_exec "userdel -f opensearch 2>/dev/null || true"
    set -e
  fi
  if remote_exec "getent group opensearch >/dev/null 2>&1"; then
    log "Removing 'opensearch' group (if present)..."
    set +e
    remote_exec "groupdel opensearch 2>/dev/null || true"
    set -e
  fi

  # Clean downloaded tarball if present
  TMP_TGZ="/tmp/opensearch-${OPENSEARCH_VERSION}-linux-x64.tar.gz"
  remote_exec "[ -f \"$TMP_TGZ\" ] && rm -f \"$TMP_TGZ\" || true"

  # Attempt to remove UFW allowances if UFW active
  if remote_exec "command -v ufw >/dev/null 2>&1"; then
    if remote_exec "ufw status | grep -q \"Status: active\""; then
      log "Removing UFW rules for OpenSearch ports (if present)..."
      for node in "${detected_nodes[@]}"; do
        local http_port=$((9199 + node))
        local transport_port=$((9299 + node))
        remote_exec "yes | ufw delete allow \"${http_port}/tcp\" >/dev/null 2>&1 || true"
        remote_exec "yes | ufw delete allow \"${transport_port}/tcp\" >/dev/null 2>&1 || true"
      done
    fi
  fi

  log "Removal complete. Removed ${#detected_nodes[@]} nodes."
}


# =========================
# Helpers
# =========================
log() { echo -e "\033[1;32m[install]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*"; }
err() { echo -e "\033[1;31m[error]\033[0m $*" >&2; }

# Calculate total system memory in GB (integer, floor)
mem_total_gb() {
  local kb
  kb="$(remote_exec "awk '/MemTotal:/ {print \$2}' /proc/meminfo 2>/dev/null || echo 0")"
  # Convert kB -> GB (floor)
  echo $(( kb / 1024 / 1024 ))
}

# Heuristic heap size: 50% of system memory divided by node count, capped at 31 GB, min 1 GB
calc_heap_gb() {
  local total_gb heap
  total_gb="$(mem_total_gb)"
  # 50% of total memory divided by node count
  heap=$(( (total_gb / 2) / NODE_COUNT ))
  # Cap to 31 GB
  if (( heap > 31 )); then
    heap=31
  fi
  # Ensure at least 1 GB
  if (( heap < 1 )); then
    heap=1
  fi
  echo "${heap}"
}

# Custom heap size with specified memory percentage
calc_heap_gb_with_percent() {
  local memory_percent="$1"
  local node_count="$2"
  local total_gb heap
  total_gb="$(mem_total_gb)"
  # Custom percentage of total memory divided by node count
  heap=$(( (total_gb * memory_percent / 100) / node_count ))
  # Cap to 31 GB
  if (( heap > 31 )); then
    heap=31
  fi
  # Ensure at least 1 GB
  if (( heap < 1 )); then
    heap=1
  fi
  echo "${heap}"
}

require_root() {
  if [[ -n "$REMOTE_IP" ]]; then
    # For remote execution, we assume sudo access
    return 0
  elif [[ "${EUID}" -ne 0 ]]; then
    err "Please run as root (sudo)."
    exit 1
  fi
}

ensure_pkg() {
  if remote_exec "command -v apt-get >/dev/null 2>&1"; then
    remote_exec "DEBIAN_FRONTEND=noninteractive apt-get update -y"
    remote_exec "DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq tar coreutils gawk procps openjdk-17-jre-headless rsync"
  else
    warn "Non-Debian system detected. Ensure curl/jq/tar/Java 17/rsync are installed."
  fi
}

sysctl_limits() {
  log "Applying kernel and ulimit settings..."
  # vm.max_map_count
  if [[ "$(remote_exec "sysctl -n vm.max_map_count")" -lt 262144 ]]; then
    remote_exec "echo 'vm.max_map_count=262144' >/etc/sysctl.d/99-opensearch.conf"
    remote_exec "sysctl --system >/dev/null"
  fi
  # nofile/nproc
  if [[ -n "$REMOTE_IP" ]]; then
    ssh "$REMOTE_IP" "sudo tee /etc/security/limits.d/opensearch.conf >/dev/null" <<EOF
opensearch soft nofile 65536
opensearch hard nofile 65536
opensearch soft nproc  4096
opensearch hard nproc  4096
EOF
  else
    cat >/etc/security/limits.d/opensearch.conf <<EOF
opensearch soft nofile 65536
opensearch hard nofile 65536
opensearch soft nproc  4096
opensearch hard nproc  4096
EOF
  fi
}

create_user() {
  log "Ensuring 'opensearch' user/group exist..."
  remote_exec "getent group opensearch >/dev/null 2>&1 || groupadd --system opensearch"
  remote_exec "id -u opensearch >/dev/null 2>&1 || useradd --system --no-create-home --gid opensearch --shell /usr/sbin/nologin opensearch"
}

download_dist() {
  if ! remote_exec "[ -d \"${BASE_DIST_DIR}\" ]"; then
    log "Downloading OpenSearch ${OPENSEARCH_VERSION} for ${OS_BUNDLE_ARCH}..."
    local TMP_TGZ="${TARBALL_PATH}"
    if ! remote_exec "[ -f \"${TMP_TGZ}\" ]"; then
      log "Fetching bundle for arch ${OS_BUNDLE_ARCH}..."
      if [[ -n "$REMOTE_IP" ]]; then
        # Download locally then copy to remote
        curl -fL "https://artifacts.opensearch.org/releases/bundle/opensearch/${OPENSEARCH_VERSION}/opensearch-${OPENSEARCH_VERSION}-${OS_BUNDLE_ARCH}.tar.gz" -o "${TMP_TGZ}"
        remote_copy "${TMP_TGZ}" "${TMP_TGZ}"
        rm -f "${TMP_TGZ}"
      else
        curl -fL "https://artifacts.opensearch.org/releases/bundle/opensearch/${OPENSEARCH_VERSION}/opensearch-${OPENSEARCH_VERSION}-${OS_BUNDLE_ARCH}.tar.gz" -o "${TMP_TGZ}"
      fi
    fi
    log "Extracting to ${BASE_DIST_DIR}..."
    remote_exec "mkdir -p \"${BASE_DIST_DIR}\""
    remote_exec "tar -xzf \"${TMP_TGZ}\" -C \"${BASE_DIR}\""
    remote_exec "mv -f \"${BASE_DIR}/opensearch-${OPENSEARCH_VERSION}\"/* \"${BASE_DIST_DIR}/\""
    remote_exec "rm -rf \"${BASE_DIR}/opensearch-${OPENSEARCH_VERSION}\""
  else
    log "Base distribution already present at ${BASE_DIST_DIR}"
  fi
  remote_exec "ln -sfn \"${BASE_DIST_DIR}\" \"${BASE_LINK}\""
}

clone_node_home() {
  local node_home="$1"
  if ! remote_exec "[ -d \"${node_home}\" ]"; then
    log "Provisioning node home at ${node_home} (copying base dist)..."
    # Copy the dist into the node home so OPENSEARCH_HOME is self-contained
    remote_exec "rsync -a --delete \"${BASE_LINK}/\" \"${node_home}/\""
    # Prepare per-node dirs
    remote_exec "mkdir -p \"${node_home}/data\" \"${node_home}/logs\" \"${node_home}/tmp\" \"${node_home}/config/jvm.options.d\""
  else
    log "Node home already exists at ${node_home}"
    # Ensure critical subdirs exist even if user pruned them
    remote_exec "mkdir -p \"${node_home}/data\" \"${node_home}/logs\" \"${node_home}/tmp\" \"${node_home}/config/jvm.options.d\""
  fi
}

write_config() {
  local node_home="$1"
  local node_name="$2"
  local http_port="$3"
  local transport_port="$4"

  log "Writing ${node_home}/config/opensearch.yml for ${node_name}..."
  
  # Build discovery seed hosts list
  local seed_hosts=""
  for i in $(seq 1 $NODE_COUNT); do
    if [ $i -eq 1 ]; then
      seed_hosts="\"127.0.0.1:${NODE_TRANSPORT_PORTS[$i]}\""
    else
      seed_hosts="${seed_hosts}, \"127.0.0.1:${NODE_TRANSPORT_PORTS[$i]}\""
    fi
  done
  
  # Build initial cluster manager nodes list (limit to first 3 nodes for large clusters)
  local manager_nodes=""
  local manager_count=$NODE_COUNT
  if (( manager_count > 3 )); then
    manager_count=3
  fi
  for i in $(seq 1 $manager_count); do
    if [ $i -eq 1 ]; then
      manager_nodes="\"node-${i}\""
    else
      manager_nodes="${manager_nodes}, \"node-${i}\""
    fi
  done

  # Create config file content
  local config_content="cluster.name: axion-cluster
node.name: ${node_name}

# Bind HTTP to all interfaces so remote curl works
network.host: 0.0.0.0
http.port: ${http_port}
transport.port: ${transport_port}

# Node discovery
discovery.seed_hosts: [${seed_hosts}]
cluster.initial_cluster_manager_nodes: [${manager_nodes}]

# Paths inside the node home
path.data: ${node_home}/data
path.logs: ${node_home}/logs

# Make bring-up easy for dev/demo (disable security plugin)
plugins.security.disabled: true

# Recommended
bootstrap.memory_lock: true"

  # Write config file using remote_exec
  if [[ -n "$REMOTE_IP" ]]; then
    echo "$config_content" | ssh "${SUDO_USER:-$USER}@${REMOTE_IP}" "sudo tee \"${node_home}/config/opensearch.yml\" >/dev/null"
  else
    echo "$config_content" > "${node_home}/config/opensearch.yml"
  fi

  # Remove any existing -Xms or -Xmx lines in jvm.options to avoid conflicts
  remote_exec "sed -i.bak '/^-Xms/d' \"${node_home}/config/jvm.options\""
  remote_exec "sed -i.bak '/^-Xmx/d' \"${node_home}/config/jvm.options\""

  # Heap settings: 50% of system memory divided by node count, capped at 31g, min 1g
  local heap_val="$(calc_heap_gb)"
  log "Setting heap for ${node_name} to ${heap_val}g (50% of RAM / ${NODE_COUNT} nodes, cap 31g)."
  
  local heap_content="-Xms${heap_val}g
-Xmx${heap_val}g"

  if [[ -n "$REMOTE_IP" ]]; then
    echo "$heap_content" | ssh "${SUDO_USER:-$USER}@${REMOTE_IP}" "sudo tee \"${node_home}/config/jvm.options.d/heap.options\" >/dev/null"
  else
    echo "$heap_content" > "${node_home}/config/jvm.options.d/heap.options"
  fi

  # jvm tweaks for containers/vm common cases (kept minimal)
  remote_exec "grep -q 'ExitOnOutOfMemoryError' \"${node_home}/config/jvm.options\" || true"
}

unit_file() {
  local svc="$1"
  local node_home="$2"
  local http_port="$3"

  log "Installing systemd unit ${svc}..."
  cat >/etc/systemd/system/${svc}.service <<EOF
[Unit]
Description=OpenSearch ${svc/opensearch-/}
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=opensearch
Group=opensearch
LimitNOFILE=65536
LimitMEMLOCK=infinity
Environment=OPENSEARCH_HOME=${node_home}
Environment=OPENSEARCH_PATH_CONF=${node_home}/config
WorkingDirectory=${node_home}
ExecStart=${node_home}/bin/opensearch
Restart=always
RestartSec=10
TimeoutStartSec=180
# IMPORTANT: do NOT chown here; ownership is handled at install time.

[Install]
WantedBy=multi-user.target
EOF
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    if ufw status | grep -q "Status: active"; then
      log "UFW is active; allowing OpenSearch ports..."
      for i in $(seq 1 $NODE_COUNT); do
        ufw allow "${NODE_HTTP_PORTS[$i]}/tcp" || true
        ufw allow "${NODE_TRANSPORT_PORTS[$i]}/tcp" || true
      done
    else
      warn "UFW not active; skipping firewall rules."
    fi
  else
    warn "ufw not installed; skipping firewall rules."
  fi
}

ownership() {
  log "Setting ownership of node homes to opensearch:opensearch (one-time)..."
  for i in $(seq 1 $NODE_COUNT); do
    chown -R opensearch:opensearch "${NODE_HOMES[$i]}"
  done
}

reload_enable_restart() {
  log "Reloading systemd units..."
  systemctl daemon-reload

  log "Enabling services..."
  for i in $(seq 1 $NODE_COUNT); do
    systemctl enable "${SERVICE_NAMES[$i]}" >/dev/null 2>&1 || true
  done

  log "Restarting services (idempotent on every run)..."
  for i in $(seq 1 $NODE_COUNT); do
    systemctl restart "${SERVICE_NAMES[$i]}" || true
  done
}

post_checks() {
  log "Waiting up to 30s for HTTP endpoints..."
  for i in $(seq 1 $NODE_COUNT); do
    SECS=0
    until curl -sf "http://127.0.0.1:${NODE_HTTP_PORTS[$i]}" >/dev/null 2>&1 || [[ $SECS -ge 30 ]]; do 
      sleep 1
      SECS=$((SECS+1))
    done
  done

  log "Local curl checks:"
  set +e
  curl -s "http://127.0.0.1:${NODE_HTTP_PORTS[1]}/_cluster/health?pretty" | jq . || true
  curl -s "http://127.0.0.1:${NODE_HTTP_PORTS[1]}/_nodes/http?pretty" | jq '._nodes, .nodes[].http' || true
  set -e

  # Show listening ports
  local port_pattern=""
  for i in $(seq 1 $NODE_COUNT); do
    if [ $i -eq 1 ]; then
      port_pattern=":${NODE_HTTP_PORTS[$i]}|:${NODE_TRANSPORT_PORTS[$i]}"
    else
      port_pattern="${port_pattern}|:${NODE_HTTP_PORTS[$i]}|:${NODE_TRANSPORT_PORTS[$i]}"
    fi
  done
  ss -ltnp | egrep "${port_pattern}" || true
}

# =========================
# Main
# =========================
action="${1:-install}"

# Handle remote execution by copying script and executing remotely
if [[ -n "$REMOTE_IP" ]]; then
  log "Remote execution detected for $REMOTE_IP"
  log "Copying installer to remote host..."
  scp "$0" "${SUDO_USER:-$USER}@${REMOTE_IP}:/tmp/dual_installer.sh"
  
  log "Executing remotely: sudo /tmp/dual_installer.sh $action${NODE_COUNT:+ $NODE_COUNT}"
  if [[ "$action" == "remove" ]]; then
    ssh "${SUDO_USER:-$USER}@${REMOTE_IP}" "sudo /tmp/dual_installer.sh remove"
  elif [[ "$action" == "update" ]]; then
    ssh "${SUDO_USER:-$USER}@${REMOTE_IP}" "sudo system_memory_percent=${system_memory_percent:-50} indices_breaker_total_limit='${indices_breaker_total_limit:-}' indices_breaker_request_limit='${indices_breaker_request_limit:-}' indices_breaker_fielddata_limit='${indices_breaker_fielddata_limit:-}' REMOTE_HOST_IP=$REMOTE_IP /tmp/dual_installer.sh update"
  else
    ssh "${SUDO_USER:-$USER}@${REMOTE_IP}" "sudo REMOTE_HOST_IP=$REMOTE_IP /tmp/dual_installer.sh $action $NODE_COUNT"
  fi
  exit $?
fi

case "$action" in
  -h|--help|help)
    usage
    exit 0
    ;;
  install)
    require_root
    ensure_pkg
    sysctl_limits
    create_user
    download_dist

    # Clone node homes and write configs
    for i in $(seq 1 $NODE_COUNT); do
      clone_node_home "${NODE_HOMES[$i]}"
      write_config "${NODE_HOMES[$i]}" "node-${i}" "${NODE_HTTP_PORTS[$i]}" "${NODE_TRANSPORT_PORTS[$i]}"
    done

    # Create systemd unit files
    for i in $(seq 1 $NODE_COUNT); do
      unit_file "${SERVICE_NAMES[$i]}" "${NODE_HOMES[$i]}" "${NODE_HTTP_PORTS[$i]}"
    done

    ownership
    open_firewall
    reload_enable_restart
    post_checks

    log "Detected total memory: $(mem_total_gb) GB; auto heap per node: $(calc_heap_gb) GB"
    log "Detected architecture: ${UNAME_M} -> ${OS_BUNDLE_ARCH}"
    log "Done. OPENSEARCH_HOME locations:"
    for i in $(seq 1 $NODE_COUNT); do
      echo "  node-${i}: ${NODE_HOMES[$i]}"
    done
    echo
    log "HTTP ports: $(for i in $(seq 1 $NODE_COUNT); do echo -n "${NODE_HTTP_PORTS[$i]} "; done)"
    
    # Generate OSB command
    echo
    echo "OpenSearch Benchmark command:"
    echo -n "opensearch-benchmark execute-test --workload=nyc_taxis --target-hosts="
    for i in $(seq 1 $NODE_COUNT); do
      if [[ -n "$REMOTE_HOST_IP" ]]; then
        host_ip="$REMOTE_HOST_IP"
      else
        host_ip="127.0.0.1"
      fi
      if [ $i -eq 1 ]; then
        echo -n "${host_ip}:${NODE_HTTP_PORTS[$i]}"
      else
        echo -n ",${host_ip}:${NODE_HTTP_PORTS[$i]}"
      fi
    done
    echo " --client-options=use_ssl:false,verify_certs:false,timeout:60 --kill-running-processes --include-tasks=\"index\" --workload-params=\"bulk_indexing_clients:90,bulk_size:10000\""
    
    if [[ -z "$REMOTE_IP" ]]; then
      log "If remote curls still RST, check your cloud/VPC firewall."
    fi
    ;;
  remove)
    require_root
    remove_install
    ;;
  update)
    require_root
    update_heap_config
    ;;
  *)
    err "Unknown action: $action"
    usage
    exit 2
    ;;
esac
