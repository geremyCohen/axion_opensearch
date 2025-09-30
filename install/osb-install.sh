#!/bin/bash

# OpenSearch Benchmark Installation Script
# Compatible with OpenSearch 3.1.x clusters
# Usage: ./install/osb-install.sh

set -e

echo "=== OpenSearch Benchmark Installation ==="
echo "Installing OSB 2.0.0 for OpenSearch 3.1.x compatibility"
echo

# Dependencies
echo "Installing system dependencies..."
sudo apt update && sudo apt install -y python3-pip python3-venv python3-full build-essential btop python3.11 python3.11-venv python3.11-dev software-properties-common

# Setup git
echo "Configuring git..."
git config --global user.name "Geremy Cohen" 2>/dev/null || true
git config --global user.email "geremy.cohen@arm.com" 2>/dev/null || true

# Setup OSB environment
echo "Setting up OpenSearch Benchmark environment..."
rm -rf ~/opensearch-benchmark-workloads
cd; git clone https://github.com/opensearch-project/opensearch-benchmark-workloads.git
sudo chown -R $USER:$USER opensearch-benchmark-workloads

echo "Creating Python virtual environment..."
python3.11 -m venv ~/opensearch-benchmark-workloads-env
source ~/opensearch-benchmark-workloads-env/bin/activate

echo "Installing OpenSearch Benchmark..."
pip install -U pip setuptools wheel
pip install "opensearch-benchmark==2.0.0"

echo
echo "=== Installation Complete ==="
echo "To use OpenSearch Benchmark:"
echo "  source ~/opensearch-benchmark-workloads-env/bin/activate"
echo "  opensearch-benchmark --version"
echo
echo "Example usage:"
echo "  opensearch-benchmark execute-test --workload=nyc_taxis --target-hosts=10.0.0.203:9200 --client-options=use_ssl:false,verify_certs:false"
echo
