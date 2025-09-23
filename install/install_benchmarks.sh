#!/bin/bash

set -e

echo "Installing OpenSearch Workloads and NY Taxi benchmark..."

# Install pip3 and python3-venv for Ubuntu 24
sudo apt update && sudo apt install -y python3-pip python3-venv python3-full

# Clean up existing directories
sudo rm -rf /opt/opensearch-benchmark-workloads
rm -rf ~/benchmark-env

# Clone OpenSearch Workloads
cd /opt
sudo git clone https://github.com/opensearch-project/opensearch-benchmark-workloads.git
sudo chown -R $USER:$USER opensearch-benchmark-workloads

# Create virtual environment and install opensearch-benchmark
python3 -m venv ~/benchmark-env
source ~/benchmark-env/bin/activate
pip install opensearch-benchmark

# Setup NY Taxi workload
cd opensearch-benchmark-workloads

echo "Setup complete. To run NY Taxi benchmark against OpenSearch 3.1:"
echo "~/benchmark-env/bin/opensearch-benchmark run --workload=nyc_taxis --target-hosts=localhost:9200 --client-options=use_ssl:false,verify_certs:false"

# Test the benchmark
echo "Running NY Taxi benchmark test..."
~/benchmark-env/bin/opensearch-benchmark run --workload=nyc_taxis --target-hosts=localhost:9200 --client-options=use_ssl:false,verify_certs:false
