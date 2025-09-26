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
HEAP_GB_NODE1="${HEAP_GB_NODE1:-2}"
HEAP_GB_NODE2="${HEAP_GB_NODE2:-2}"

# Fixed install locations (do not change at runtime)
BASE_DIR="/opt"
BASE_DIST_DIR="${BASE_DIR}/opensearch-dist-${OPENSEARCH_VERSION}"
BASE_LINK="${BASE_DIR}/opensearch-dist"            # stable pointer to the dist
NODE1_HOME="${BASE_DIR}/opensearch-node1"          # OPENSEARCH_HOME for node-1 (fixed)
NODE2_HOME="${BASE_DIR}/opensearch-node2"          # OPENSEARCH_HOME for node-2 (fixed)

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
    log "Downloading OpenSearch ${OPENSEARCH_VERSION}..."
    TMP_TGZ="/tmp/opensearch-${OPENSEARCH_VERSION}-linux-x64.tar.gz"
    if [[ ! -f "${TMP_TGZ}" ]]; then
      curl -fL "https://artifacts.opensearch.org/releases/bundle/opensearch/${OPENSEARCH_VERSION}/opensearch-${OPENSEARCH_VERSION}-linux-x64.tar.gz" -o "${TMP_TGZ}"
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
EOF

  # Remove any existing -Xms or -Xmx lines in jvm.options to avoid conflicts
  sed -i.bak '/^-Xms/d' "${node_home}/config/jvm.options"
  sed -i.bak '/^-Xmx/d' "${node_home}/config/jvm.options"

  # Heap settings - use HEAP_GB_NODE1 or HEAP_GB_NODE2 env var if set, else default to 8g
  local heap_val=8
  if [[ "${node_name}" == "node-1" ]]; then
    heap_val="${HEAP_GB_NODE1:-8}"
  elif [[ "${node_name}" == "node-2" ]]; then
    heap_val="${HEAP_GB_NODE2:-8}"
  fi
  log "Setting heap for ${node_name} to ${heap_val}g..."
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
