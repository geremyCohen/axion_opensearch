#!/usr/bin/env bash
set -euo pipefail

echo "=== Node 1 (9200) ==="
curl -s http://127.0.0.1:9200/ | jq .

echo
echo "=== Node 2 (9201) ==="
curl -s http://127.0.0.1:9201/ | jq .

echo
echo "=== Cluster Health ==="
curl -s http://127.0.0.1:9200/_cluster/health?pretty

echo
echo "=== Nodes in Cluster ==="
curl -s http://127.0.0.1:9200/_cat/nodes?v