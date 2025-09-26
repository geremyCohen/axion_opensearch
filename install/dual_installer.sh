#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 <install|remove>
  install  Install or upgrade OpenSearch dual-node (default if omitted)
  remove   Stop services and remove all non-apt artifacts created by install
USAGE
}

# =========================
# Configurable parameters
# =========================
OPENSEARCH_VERSION="${OPENSEARCH_VERSION:-2.13.0}"
HEAP_GB_NODE1="${HEAP_GB_NODE1:-auto}"
HEAP_GB_NODE2="${HEAP_GB_NODE2:-auto}"

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
NODE1_HOME="${BASE_DIR}/opensearch-node1"          # OPENSEARCH_HOME for node-1 (fixed)
NODE2_HOME="${BASE_DIR}/opensearch-node2"          # OPENSEARCH_HOME for node-2 (fixed)

TARBALL_PATH="/tmp/opensearch-${OPENSEARCH_VERSION}-${OS_BUNDLE_ARCH}.tar.gz"

# Ports
N1_HTTP=9200
N1_TRANSPORT=9300
N2_HTTP=9201
N2_TRANSPORT=9301

# Service names
SVC1="opensearch-node1"
SVC2="opensearch-node2"

remove_install() {
  log "Stopping services if running..."
  set +e
  systemctl stop "${SVC1}" 2>/dev/null || true
  systemctl stop "${SVC2}" 2>/dev/null || true
  set -e

  log "Disabling services..."
  set +e
  systemctl disable "${SVC1}" 2>/dev/null || true
  systemctl disable "${SVC2}" 2>/dev/null || true
  set -e

  log "Removing systemd unit files..."
  rm -f "/etc/systemd/system/${SVC1}.service" "/etc/systemd/system/${SVC2}.service"
  systemctl daemon-reload || true

  log "Removing node homes and base distribution..."
  rm -rf "${NODE1_HOME}" "${NODE2_HOME}"
  rm -rf "${BASE_DIST_DIR}"
  rm -f "${BASE_LINK}"

  log "Removing installer-created sysctl and limits files..."
  rm -f /etc/sysctl.d/99-opensearch.conf
  sysctl --system >/dev/null 2>&1 || true
  rm -f /etc/security/limits.d/opensearch.conf

  # Optional: remove opensearch user/group if unused
  if id -u opensearch >/dev/null 2>&1; then
    log "Removing 'opensearch' system user (if present)..."
    set +e
    userdel -f opensearch 2>/dev/null || true
    set -e
  fi
  if getent group opensearch >/dev/null 2>&1; then
    log "Removing 'opensearch' group (if present)..."
    set +e
    groupdel opensearch 2>/dev/null || true
    set -e
  fi

  # Clean downloaded tarball if present
  TMP_TGZ="/tmp/opensearch-${OPENSEARCH_VERSION}-linux-x64.tar.gz"
  [ -f "$TMP_TGZ" ] && rm -f "$TMP_TGZ"

  # Attempt to remove UFW allowances if UFW active
  if command -v ufw >/dev/null 2>&1; then
    if ufw status | grep -q "Status: active"; then
      log "Removing UFW rules for OpenSearch ports (if present)..."
      yes | ufw delete allow "${N1_HTTP}/tcp" >/dev/null 2>&1 || true
      yes | ufw delete allow "${N2_HTTP}/tcp" >/dev/null 2>&1 || true
      yes | ufw delete allow "${N1_TRANSPORT}/tcp" >/dev/null 2>&1 || true
      yes | ufw delete allow "${N2_TRANSPORT}/tcp" >/dev/null 2>&1 || true
    fi
  fi

  log "Removal complete."
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
  kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  # Convert kB -> GB (floor)
  echo $(( kb / 1024 / 1024 ))
}

# Heuristic heap size: 25% of system memory, capped at 31 GB, min 1 GB
calc_heap_gb() {
  local total_gb heap
  total_gb="$(mem_total_gb)"
  # 25% of total memory
  heap=$(( total_gb / 4 ))
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
  if [[ "${EUID}" -ne 0 ]]; then
    err "Please run as root (sudo)."
    exit 1
  fi
}

ensure_pkg() {
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq tar coreutils gawk procps openjdk-17-jre-headless
  else
    warn "Non-Debian system detected. Ensure curl/jq/tar/Java 17 are installed."
  fi
}

sysctl_limits() {
  log "Applying kernel and ulimit settings..."
  # vm.max_map_count
  if [[ "$(sysctl -n vm.max_map_count)" -lt 262144 ]]; then
    echo "vm.max_map_count=262144" >/etc/sysctl.d/99-opensearch.conf
    sysctl --system >/dev/null
  fi
  # nofile/nproc
  cat >/etc/security/limits.d/opensearch.conf <<EOF
opensearch soft nofile 65536
opensearch hard nofile 65536
opensearch soft nproc  4096
opensearch hard nproc  4096
EOF
}

create_user() {
  log "Ensuring 'opensearch' user/group exist..."
  getent group opensearch >/dev/null 2>&1 || groupadd --system opensearch
  id -u opensearch >/dev/null 2>&1 || useradd --system --no-create-home --gid opensearch --shell /usr/sbin/nologin opensearch
}

download_dist() {
  if [[ ! -d "${BASE_DIST_DIR}" ]]; then
    log "Downloading OpenSearch ${OPENSEARCH_VERSION} for ${OS_BUNDLE_ARCH}..."
    local TMP_TGZ="${TARBALL_PATH}"
    if [[ ! -f "${TMP_TGZ}" ]]; then
      log "Fetching bundle for arch ${OS_BUNDLE_ARCH}..."
      curl -fL "https://artifacts.opensearch.org/releases/bundle/opensearch/${OPENSEARCH_VERSION}/opensearch-${OPENSEARCH_VERSION}-${OS_BUNDLE_ARCH}.tar.gz" -o "${TMP_TGZ}"
    fi
    log "Extracting to ${BASE_DIST_DIR}..."
    mkdir -p "${BASE_DIST_DIR}"
    tar -xzf "${TMP_TGZ}" -C "${BASE_DIR}"
    mv -f "${BASE_DIR}/opensearch-${OPENSEARCH_VERSION}"/* "${BASE_DIST_DIR}/"
    rm -rf "${BASE_DIR}/opensearch-${OPENSEARCH_VERSION}"
  else
    log "Base distribution already present at ${BASE_DIST_DIR}"
  fi
  ln -sfn "${BASE_DIST_DIR}" "${BASE_LINK}"
}

clone_node_home() {
  local node_home="$1"
  if [[ ! -d "${node_home}" ]]; then
    log "Provisioning node home at ${node_home} (copying base dist)..."
    # Copy the dist into the node home so OPENSEARCH_HOME is self-contained
    rsync -a --delete "${BASE_LINK}/" "${node_home}/"
    # Prepare per-node dirs
    mkdir -p "${node_home}/data" "${node_home}/logs" "${node_home}/tmp" "${node_home}/config/jvm.options.d"
  else
    log "Node home already exists at ${node_home}"
    # Ensure critical subdirs exist even if user pruned them
    mkdir -p "${node_home}/data" "${node_home}/logs" "${node_home}/tmp" "${node_home}/config/jvm.options.d"
  fi
}

write_config() {
  local node_home="$1"
  local node_name="$2"
  local http_port="$3"
  local transport_port="$4"
  local peer1="$5"
  local peer2="$6"

  log "Writing ${node_home}/config/opensearch.yml for ${node_name}..."
  cat >"${node_home}/config/opensearch.yml" <<EOF
cluster.name: axion-dual
node.name: ${node_name}

# Bind HTTP to all interfaces so remote curl works
network.host: 0.0.0.0
http.port: ${http_port}
transport.port: ${transport_port}

# Two-node discovery on localhost transports
discovery.seed_hosts: ["127.0.0.1:${N1_TRANSPORT}", "127.0.0.1:${N2_TRANSPORT}"]
cluster.initial_cluster_manager_nodes: ["node-1","node-2"]

# Paths inside the node home
path.data: ${node_home}/data
path.logs: ${node_home}/logs

# Make bring-up easy for dev/demo (disable security plugin)
plugins.security.disabled: true

# Recommended
bootstrap.memory_lock: true

# Indexing performance optimizations
indices.memory.index_buffer_size: 40%
thread_pool.write.size: 16
thread_pool.write.queue_size: 1000
action.auto_create_index: true
EOF

  # Remove any existing -Xms or -Xmx lines in jvm.options to avoid conflicts
  sed -i.bak '/^-Xms/d' "${node_home}/config/jvm.options"
  sed -i.bak '/^-Xmx/d' "${node_home}/config/jvm.options"

  # Heap settings:
  # - If HEAP_GB_NODE1/HEAP_GB_NODE2 are provided, use them.
  # - Otherwise, set to 25% of system memory (capped at 31g).
  local heap_val
  if [[ "${node_name}" == "node-1" ]]; then
    if [[ "${HEAP_GB_NODE1}" == "auto" || -z "${HEAP_GB_NODE1}" ]]; then
      heap_val="$(calc_heap_gb)"
    else
      heap_val="${HEAP_GB_NODE1}"
    fi
  elif [[ "${node_name}" == "node-2" ]]; then
    if [[ "${HEAP_GB_NODE2}" == "auto" || -z "${HEAP_GB_NODE2}" ]]; then
      heap_val="$(calc_heap_gb)"
    else
      heap_val="${HEAP_GB_NODE2}"
    fi
  else
    heap_val="$(calc_heap_gb)"
  fi

  log "Setting heap for ${node_name} to ${heap_val}g (25% of RAM, cap 31g; override with HEAP_GB_NODEX)."
  cat >"${node_home}/config/jvm.options.d/heap.options" <<EOF
-Xms${heap_val}g
-Xmx${heap_val}g
EOF

  # jvm tweaks for containers/vm common cases (kept minimal)
  grep -q 'ExitOnOutOfMemoryError' "${node_home}/config/jvm.options" || true
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
      log "UFW is active; allowing OpenSearch ports ${N1_HTTP},${N2_HTTP},${N1_TRANSPORT},${N2_TRANSPORT}..."
      ufw allow "${N1_HTTP}/tcp" || true
      ufw allow "${N2_HTTP}/tcp" || true
      ufw allow "${N1_TRANSPORT}/tcp" || true
      ufw allow "${N2_TRANSPORT}/tcp" || true
    else
      warn "UFW not active; skipping firewall rules."
    fi
  else
    warn "ufw not installed; skipping firewall rules."
  fi
}

ownership() {
  log "Setting ownership of node homes to opensearch:opensearch (one-time)..."
  chown -R opensearch:opensearch "${NODE1_HOME}" "${NODE2_HOME}"
}

reload_enable_restart() {
  log "Reloading systemd units..."
  systemctl daemon-reload

  log "Enabling services ${SVC1} and ${SVC2}..."
  systemctl enable "${SVC1}" "${SVC2}" >/dev/null 2>&1 || true

  log "Restarting services (idempotent on every run)..."
  systemctl restart "${SVC1}" || true
  systemctl restart "${SVC2}" || true
}

post_checks() {
  log "Waiting up to 30s for HTTP endpoints..."
  SECS=0
  until curl -sf "http://127.0.0.1:${N1_HTTP}" >/dev/null 2>&1 || [[ $SECS -ge 30 ]]; do sleep 1; SECS=$((SECS+1)); done
  SECS=0
  until curl -sf "http://127.0.0.1:${N2_HTTP}" >/dev/null 2>&1 || [[ $SECS -ge 30 ]]; do sleep 1; SECS=$((SECS+1)); done

  log "Creating performance-optimized index template..."
  curl -X PUT "http://127.0.0.1:${N1_HTTP}/_index_template/performance_template" -H 'Content-Type: application/json' -d '{
    "index_patterns": ["*"],
    "priority": 1,
    "template": {
      "settings": {
        "refresh_interval": "30s"
      }
    }
  }' >/dev/null 2>&1 || true

  log "Local curl checks:"
  set +e
  curl -s "http://127.0.0.1:${N1_HTTP}/_cluster/health?pretty" | jq . || true
  curl -s "http://127.0.0.1:${N2_HTTP}/_nodes/http?pretty" | jq '._nodes, .nodes[].http' || true
  set -e

  ss -ltnp | egrep ":${N1_HTTP}|:${N2_HTTP}|:${N1_TRANSPORT}|:${N2_TRANSPORT}" || true
}

# =========================
# Main
# =========================
action="${1:-install}"
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

    clone_node_home "${NODE1_HOME}"
    clone_node_home "${NODE2_HOME}"

    write_config "${NODE1_HOME}" "node-1" "${N1_HTTP}" "${N1_TRANSPORT}" "${N1_TRANSPORT}" "${N2_TRANSPORT}"
    write_config "${NODE2_HOME}" "node-2" "${N2_HTTP}" "${N2_TRANSPORT}" "${N1_TRANSPORT}" "${N2_TRANSPORT}"

    unit_file "${SVC1}" "${NODE1_HOME}" "${N1_HTTP}"
    unit_file "${SVC2}" "${NODE2_HOME}" "${N2_HTTP}"

    ownership
    open_firewall
    reload_enable_restart
    post_checks

    log "Detected total memory: $(mem_total_gb) GB; auto heap per node: $(calc_heap_gb) GB"
    log "Detected architecture: ${UNAME_M} -> ${OS_BUNDLE_ARCH}"
    log "Done. OPENSEARCH_HOME locations:"
    echo "  node-1: ${NODE1_HOME}"
    echo "  node-2: ${NODE2_HOME}"
    echo
    log "If remote curls still RST, check your cloud/VPC firewall (ingress to 9200/9201)."
    ;;
  remove)
    require_root
    # Ports/service names and paths are already defined above.
    remove_install
    ;;
  *)
    err "Unknown action: $action"
    usage
    exit 2
    ;;
esac
