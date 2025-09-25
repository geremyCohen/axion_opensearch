#!/usr/bin/env bash
set -euo pipefail

### --- Config (change if you want) ---
OS_VERSION="3.1.0"
OS_TARBALL="opensearch-${OS_VERSION}-linux-x64.tar.gz"
OS_URL="https://artifacts.opensearch.org/releases/bundle/opensearch/${OS_VERSION}/${OS_TARBALL}"
OS_HOME="/opt/opensearch"                # << fixed, never changes
NODE1_DIR="/opt/opensearch-node1"
NODE2_DIR="/opt/opensearch-node2"
CLUSTER_NAME="opensearch-dual"
NODE1_HTTP_PORT=9200
NODE1_TRANSPORT_PORT=9300
NODE2_HTTP_PORT=9201
NODE2_TRANSPORT_PORT=9301
HEAP_GB="${HEAP_GB:-1}"                  # override by env if desired
DISABLE_SECURITY="${DISABLE_SECURITY:-true}"   # set to "false" for prod & add TLS
DISABLE_PA="${DISABLE_PA:-true}"         # Disable Performance Analyzer to reduce background CPU
JAVA_PACKAGE="${JAVA_PACKAGE:-openjdk-21-jdk}" # OpenSearch 3.x expects Java 21
### -----------------------------------

if [[ $EUID -ne 0 ]]; then
  echo "[opensearch-dual] Please run as root (sudo)." >&2
  exit 1
fi

log() { echo "[opensearch-dual] $*"; }

# 1) Basics & prerequisites
log "Installing prerequisites"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl tar ${JAVA_PACKAGE}

# Kernel & limits (safe on repeat)
log "Tuning kernel limits (vm.max_map_count)"
sysctl -w vm.max_map_count=262144 >/dev/null
grep -q 'vm.max_map_count' /etc/sysctl.conf || echo 'vm.max_map_count=262144' >> /etc/sysctl.conf

if ! id opensearch >/dev/null 2>&1; then
  log "Creating user/group 'opensearch'"
  groupadd --system opensearch
  useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin --gid opensearch opensearch
fi

# 2) Install OpenSearch at fixed path /opt/opensearch
#    We download to a temp dir and extract directly into /opt/opensearch (no versioned path).
install_opensearch() {
  local tmp
  tmp="$(mktemp -d)"
  log "Downloading OpenSearch ${OS_VERSION}"
  curl -fL "${OS_URL}" -o "${tmp}/${OS_TARBALL}"
  rm -rf "${OS_HOME}"
  mkdir -p "${OS_HOME}"
  log "Extracting to ${OS_HOME}"
  tar -xzf "${tmp}/${OS_TARBALL}" --strip-components=1 -C "${OS_HOME}"
  rm -rf "${tmp}"
  chmod +x "${OS_HOME}/bin/opensearch" "${OS_HOME}/bin/opensearch-plugin"
  chown -R opensearch:opensearch "${OS_HOME}"
}

if [[ ! -x "${OS_HOME}/bin/opensearch" ]]; then
  install_opensearch
else
  log "OpenSearch already present at ${OS_HOME} (skipping download)."
fi

# 3) Create per-node layouts
for node in "${NODE1_DIR}" "${NODE2_DIR}"; do
  mkdir -p "${node}/config/jvm.options.d" "${node}/data" "${node}/logs"
done
chown -R opensearch:opensearch "${NODE1_DIR}" "${NODE2_DIR}"

# JVM heap (per node, read from jvm.options.d under *each* node's config)
cat > "${NODE1_DIR}/config/jvm.options.d/heap.options" <<EOF
-Xms${HEAP_GB}g
-Xmx${HEAP_GB}g
EOF

cp "${NODE1_DIR}/config/jvm.options.d/heap.options" "${NODE2_DIR}/config/jvm.options.d/heap.options"
chown -R opensearch:opensearch "${NODE1_DIR}/config" "${NODE2_DIR}/config"

# 4) Minimal configs for each node
# Shared discovery seeds (loopback)
DISCOVERY_SEEDS="127.0.0.1:${NODE1_TRANSPORT_PORT},127.0.0.1:${NODE2_TRANSPORT_PORT}"

cat > "${NODE1_DIR}/config/opensearch.yml" <<EOF
cluster.name: ${CLUSTER_NAME}
node.name: node-1
path.data: ${NODE1_DIR}/data
path.logs: ${NODE1_DIR}/logs
network.host: 127.0.0.1
http.port: ${NODE1_HTTP_PORT}
transport.port: ${NODE1_TRANSPORT_PORT}
discovery.seed_hosts: [ "127.0.0.1:${NODE1_TRANSPORT_PORT}", "127.0.0.1:${NODE2_TRANSPORT_PORT}" ]
cluster.initial_cluster_manager_nodes: [ "node-1", "node-2" ]
plugins.security.disabled: ${DISABLE_SECURITY}
EOF

cat > "${NODE2_DIR}/config/opensearch.yml" <<EOF
cluster.name: ${CLUSTER_NAME}
node.name: node-2
path.data: ${NODE2_DIR}/data
path.logs: ${NODE2_DIR}/logs
network.host: 127.0.0.1
http.port: ${NODE2_HTTP_PORT}
transport.port: ${NODE2_TRANSPORT_PORT}
discovery.seed_hosts: [ "127.0.0.1:${NODE1_TRANSPORT_PORT}", "127.0.0.1:${NODE2_TRANSPORT_PORT}" ]
cluster.initial_cluster_manager_nodes: [ "node-1", "node-2" ]
plugins.security.disabled: ${DISABLE_SECURITY}
EOF

chown -R opensearch:opensearch "${NODE1_DIR}/config" "${NODE1_DIR}/data" "${NODE1_DIR}/logs" \
                                  "${NODE2_DIR}/config" "${NODE2_DIR}/data" "${NODE2_DIR}/logs"

# 5) Systemd units with RuntimeDirectory and fixed paths
make_unit() {
  local svc="$1" node_dir="$2" runtime_name="$3" pa_flag="$4"
  cat > "/etc/systemd/system/${svc}.service" <<EOF
[Unit]
Description=OpenSearch ${svc/-/ }
After=network.target

[Service]
Type=simple
User=opensearch
Group=opensearch
Environment=OPENSEARCH_HOME=${OS_HOME}
Environment=OPENSEARCH_PATH_CONF=${node_dir}/config
Environment=DISABLE_PERFORMANCE_ANALYZER=${pa_flag}
# Force JVM tmp inside a safe, auto-created runtime dir
RuntimeDirectory=${runtime_name}
RuntimeDirectoryMode=0750
Environment=JAVA_TOOL_OPTIONS=-Djava.io.tmpdir=/run/${runtime_name}
# Create only persistent dirs here (tmp is handled by RuntimeDirectory)
ExecStartPre=/bin/mkdir -p ${node_dir}/logs ${node_dir}/data
ExecStart=/opt/opensearch/bin/opensearch
LimitNOFILE=65535
LimitMEMLOCK=infinity
TimeoutStartSec=180
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

log "Creating systemd units"
make_unit "opensearch-node1" "${NODE1_DIR}" "opensearch-node1" "${DISABLE_PA}"
make_unit "opensearch-node2" "${NODE2_DIR}" "opensearch-node2" "${DISABLE_PA}"

systemctl daemon-reload
systemctl enable opensearch-node1 opensearch-node2

# 6) Start both nodes
log "Starting node-1"
systemctl restart opensearch-node1 || true
log "Starting node-2"
systemctl restart opensearch-node2 || true

# 7) Wait for HTTP (best-effort)
wait_for() {
  local port="$1" name="$2" secs=60
  for i in $(seq 1 $secs); do
    if curl -fsS "http://127.0.0.1:${port}" >/dev/null 2>&1; then
      log "${name} is responding on :${port}"
      return 0
    fi
    sleep 1
  done
  log "Timed out waiting for ${name} on :${port} (check systemd logs)"
  return 1
}

wait_for "${NODE1_HTTP_PORT}" "node-1" || true
wait_for "${NODE2_HTTP_PORT}" "node-2" || true

# 8) Quick status dump
log "Service status (first 20 lines each)"
systemctl status opensearch-node1 --no-pager | head -n 20 || true
echo
systemctl status opensearch-node2 --no-pager | head -n 20 || true
echo

# 9) Hints
cat <<'HINTS'

Next steps / quick checks:

  # Logs (follow)
  sudo journalctl -fu opensearch-node1 -u opensearch-node2

  # Health & nodes (security disabled by default)
  curl -s http://127.0.0.1:9200/_cluster/health?pretty
  curl -s http://127.0.0.1:9200/_cat/nodes?v

If you see repeated "cluster-manager not discovered yet" warnings for >1–2 minutes,
ensure both services are up and that ports 9300/9301 are free.

To re-run with a different heap size:
  HEAP_GB=2 sudo bash dual_installer.sh

To enable Security (TLS and auth), set DISABLE_SECURITY=false and configure certs.
HINTS

log "Done."
