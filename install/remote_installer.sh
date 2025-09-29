#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 [install|remove] [node_count] [remote_ip]
  install     Install or upgrade OpenSearch cluster (default if omitted)
  remove      Stop services and remove all non-apt artifacts created by install
  node_count  Number of nodes to install (default: 2)
  remote_ip   Remote host IP for SSH installation (required)

Examples:
  $0 install 4 10.0.0.205        # Install 4-node cluster on remote host
  $0 remove 4 10.0.0.205         # Remove 4-node cluster from remote host
USAGE
}

# =========================
# Parameters
# =========================
ACTION="${1:-install}"
NODE_COUNT="${2:-2}"
REMOTE_IP="${3:-}"

if [[ -z "$REMOTE_IP" ]]; then
  echo "[error] Remote IP is required for remote installation" >&2
  usage
  exit 1
fi

# Validate node count
if ! [[ "$NODE_COUNT" =~ ^[1-9][0-9]*$ ]] || [ "$NODE_COUNT" -gt 10 ]; then
  echo "[error] Invalid node count: $NODE_COUNT. Must be 1-10" >&2
  exit 1
fi

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_SCRIPT="${SCRIPT_DIR}/dual_installer.sh"

if [[ ! -f "$INSTALLER_SCRIPT" ]]; then
  echo "[error] dual_installer.sh not found at $INSTALLER_SCRIPT" >&2
  exit 1
fi

echo "[remote] Copying installer to remote host $REMOTE_IP..."
scp "$INSTALLER_SCRIPT" "$REMOTE_IP:/tmp/dual_installer.sh"

echo "[remote] Executing remote installation: $ACTION $NODE_COUNT nodes on $REMOTE_IP"
ssh "$REMOTE_IP" "sudo /tmp/dual_installer.sh $ACTION $NODE_COUNT"

echo "[remote] Remote installation completed successfully"

if [[ "$ACTION" == "install" ]]; then
  echo ""
  echo "OpenSearch cluster is now running on $REMOTE_IP with $NODE_COUNT nodes:"
  for i in $(seq 1 $NODE_COUNT); do
    port=$((9199 + i))
    echo "  Node $i: http://$REMOTE_IP:$port"
  done
  echo ""
  echo "Example OSB command:"
  echo -n "~/benchmark-env/bin/opensearch-benchmark execute-test --workload=nyc_taxis --target-hosts="
  for i in $(seq 1 $NODE_COUNT); do
    port=$((9199 + i))
    if [ $i -eq 1 ]; then
      echo -n "$REMOTE_IP:$port"
    else
      echo -n ",$REMOTE_IP:$port"
    fi
  done
  echo " --client-options=use_ssl:false,verify_certs:false,timeout:60 --kill-running-processes --include-tasks=\"index\" --workload-params=\"bulk_indexing_clients:90,bulk_size:10000\""
fi
