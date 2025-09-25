#!/usr/bin/env bash
set -euo pipefail

### Config
OS_VERSION="3.1.0"
OS_URL="https://artifacts.opensearch.org/releases/bundle/opensearch/${OS_VERSION}/opensearch-${OS_VERSION}-linux-x64.tar.gz"

INSTALL_ROOT="/opt"
OS_VERSION_DIR="${INSTALL_ROOT}/opensearch-${OS_VERSION}"
OS_HOME="${INSTALL_ROOT}/opensearch"
NODE1_HOME="${INSTALL_ROOT}/opensearch-node1"
NODE2_HOME="${INSTALL_ROOT}/opensearch-node2"

OS_USER="opensearch"
OS_GROUP="opensearch"

NODE1_HTTP=9200
NODE1_TRANSPORT=9300
NODE2_HTTP=9201
NODE2_TRANSPORT=9301

# Heap (per node)
HEAP_GB=1

# Get host IP for publish
HOST_IP=$(hostname -I | awk '{print $1}')

### Ensure user/group
if ! getent group "${OS_GROUP}" >/dev/null; then
  groupadd --system "${OS_GROUP}"
fi
if ! id -u "${OS_USER}" >/dev/null 2>&1; then
  useradd --system --home-dir "${INSTALL_ROOT}" --shell /usr/sbin/nologin -g "${OS_GROUP}" "${OS_USER}"
fi

### Sysctl
if [[ "$(sysctl -n vm.max_map_count)" -lt 262144 ]]; then
  sysctl -w vm.max_map_count=262144
  echo "vm.max_map_count=262144" >/etc/sysctl.d/99-opensearch.conf
fi

### Download & extract
if [[ ! -d "${OS_VERSION_DIR}" ]]; then
  curl -fsSLO "${OS_URL}"
  tar -xf "opensearch-${OS_VERSION}-linux-x64.tar.gz"
  mv "opensearch-${OS_VERSION}" "${OS_VERSION_DIR}"
fi

ln -sfn "${OS_VERSION_DIR}" "${OS_HOME}"
chown -R "${OS_USER}:${OS_GROUP}" "${OS_VERSION_DIR}"

### Create node homes
for NODE in "${NODE1_HOME}" "${NODE2_HOME}"; do
  mkdir -p "${NODE}"/{config,data,logs,tmp,jvm.options.d}
  chown -R "${OS_USER}:${OS_GROUP}" "${NODE}"
done

### Configs
cat >"${NODE1_HOME}/config/opensearch.yml" <<EOF
cluster.name: dual-cluster
node.name: node-1
node.roles: [ cluster_manager, data, ingest ]

path.data: ${NODE1_HOME}/data
path.logs: ${NODE1_HOME}/logs

http.port: ${NODE1_HTTP}
transport.port: ${NODE1_TRANSPORT}

network.host: 0.0.0.0
network.publish_host: ${HOST_IP}

discovery.seed_hosts: ["${HOST_IP}:${NODE1_TRANSPORT}","${HOST_IP}:${NODE2_TRANSPORT}"]
cluster.initial_master_nodes: ["node-1","node-2"]

plugins.security.disabled: true
EOF

cat >"${NODE2_HOME}/config/opensearch.yml" <<EOF
cluster.name: dual-cluster
node.name: node-2
node.roles: [ cluster_manager, data, ingest ]

path.data: ${NODE2_HOME}/data
path.logs: ${NODE2_HOME}/logs

http.port: ${NODE2_HTTP}
transport.port: ${NODE2_TRANSPORT}

network.host: 0.0.0.0
network.publish_host: ${HOST_IP}

discovery.seed_hosts: ["${HOST_IP}:${NODE1_TRANSPORT}","${HOST_IP}:${NODE2_TRANSPORT}"]
cluster.initial_master_nodes: ["node-1","node-2"]

plugins.security.disabled: true
EOF

### JVM options
for NODE in "${NODE1_HOME}" "${NODE2_HOME}"; do
  cat >"${NODE}/jvm.options.d/heap.options" <<EOF
-Xms${HEAP_GB}g
-Xmx${HEAP_GB}g
-Djava.io.tmpdir=${NODE}/tmp
EOF
done

### systemd units
cat >/etc/systemd/system/opensearch-node1.service <<EOF
[Unit]
Description=OpenSearch node-1
After=network.target

[Service]
Type=notify
User=${OS_USER}
Group=${OS_GROUP}
Environment=OPENSEARCH_HOME=${OS_HOME}
Environment=OPENSEARCH_PATH_CONF=${NODE1_HOME}/config
Environment=OPENSEARCH_TMPDIR=${NODE1_HOME}/tmp
ExecStartPre=/bin/mkdir -p ${NODE1_HOME}/tmp ${NODE1_HOME}/logs ${NODE1_HOME}/data
ExecStartPre=/bin/chown -R ${OS_USER}:${OS_GROUP} ${NODE1_HOME}
ExecStart=${OS_HOME}/bin/opensearch
LimitNOFILE=65535
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/opensearch-node2.service <<EOF
[Unit]
Description=OpenSearch node-2
After=network.target

[Service]
Type=notify
User=${OS_USER}
Group=${OS_GROUP}
Environment=OPENSEARCH_HOME=${OS_HOME}
Environment=OPENSEARCH_PATH_CONF=${NODE2_HOME}/config
Environment=OPENSEARCH_TMPDIR=${NODE2_HOME}/tmp
ExecStartPre=/bin/mkdir -p ${NODE2_HOME}/tmp ${NODE2_HOME}/logs ${NODE2_HOME}/data
ExecStartPre=/bin/chown -R ${OS_USER}:${OS_GROUP} ${NODE2_HOME}
ExecStart=${OS_HOME}/bin/opensearch
LimitNOFILE=65535
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

### Reload & restart
systemctl daemon-reload
systemctl enable opensearch-node1.service opensearch-node2.service
systemctl restart opensearch-node1.service opensearch-node2.service

echo "Install complete. Check cluster with:"
echo "  curl -s http://${HOST_IP}:${NODE1_HTTP}/_cat/nodes?v"
