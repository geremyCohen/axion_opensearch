#!/bin/bash

set -e

echo "Installing OpenSearch Workloads and NY Taxi benchmark..."

# Install pip3 and python3-venv for Ubuntu 24
sudo apt update && sudo apt install -y python3-pip python3-venv python3-full build-essential btop

# Configure git if not already done
git config --global user.name "Geremy Cohen" 2>/dev/null || true
git config --global user.email "geremy.cohen@arm.com" 2>/dev/null || true

# Clone axion_opensearch repo if not in current directory
if [ ! -f "README.md" ] || ! grep -q "axion_opensearch" README.md 2>/dev/null; then
    echo "Cloning axion_opensearch repository..."
    cd ~
    git clone git@github.com:geremyCohen/axion_opensearch.git || git clone https://github.com/geremyCohen/axion_opensearch.git
    cd axion_opensearch
fi

# Clean up existing directories
# sudo rm -rf /opt/opensearch-benchmark-workloads
rm -rf ~/benchmark-env

# Clone OpenSearch Workloads
cd /opt
sudo git clone https://github.com/opensearch-project/opensearch-benchmark-workloads.git
sudo chown -R $USER:$USER opensearch-benchmark-workloads

# Create virtual environment and install opensearch-benchmark (force Python 3.11)
# Install Python 3.11 on Ubuntu 24.04 via Deadsnakes PPA
sudo apt update
sudo apt install -y software-properties-common
sudo add-apt-repository -y ppa:deadsnakes/ppa
sudo apt install -y python3.11 python3.11-venv python3.11-dev
python3.11 -m venv ~/benchmark-env
source ~/benchmark-env/bin/activate
pip install -U pip setuptools wheel
pip install "opensearch-benchmark<1.16"

# Setup NY Taxi workload
cd opensearch-benchmark-workloads

# Test the benchmark
echo "Running NY Taxi benchmark test..."

sudo systemctl restart opensearch
~/benchmark-env/bin/opensearch-benchmark execute-test --workload=nyc_taxis --target-hosts=10.0.0.52:9200 --client-options=use_ssl:false,verify_certs:false
curl -s http://10.0.0.52:9200/_nodes/stats/indices | jq '
  .nodes[] | {
    merges_total_time: .indices.merges.total_time_in_millis,
    indexing_total_time: .indices.indexing.index_time_in_millis,
    refresh_total_time: .indices.refresh.total_time_in_millis,
    flush_total_time: .indices.flush.total_time_in_millis
  }'

  Run
  clean.sh
  to start opensearch