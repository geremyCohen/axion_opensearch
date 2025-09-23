#!/bin/bash
set -e

echo "Installing OpenSearch 3.1.0 on Google Axion (Ubuntu 24)..."

# Update system and install dependencies
sudo apt update && sudo apt upgrade -y
sudo apt install -y default-jdk curl wget git unzip

# For Ubuntu 24, prefer OpenJDK 21, fallback to 17
if ! dpkg -l | grep -q openjdk-21-jdk; then
    if apt-cache show openjdk-21-jdk >/dev/null 2>&1; then
        sudo apt install -y openjdk-21-jdk
    else
        sudo apt install -y openjdk-17-jdk
    fi
fi

# Download and install OpenSearch 3.1.0
cd /opt
sudo wget https://artifacts.opensearch.org/releases/bundle/opensearch/3.1.0/opensearch-3.1.0-linux-arm64.tar.gz
sudo tar -xzf opensearch-3.1.0-linux-arm64.tar.gz
sudo mv opensearch-3.1.0 opensearch
sudo chown -R $USER:$USER opensearch

# Ubuntu 24 OS tweaks
echo 'vm.max_map_count=262144' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
echo "$USER soft nofile 65536" | sudo tee -a /etc/security/limits.conf
echo "$USER hard nofile 65536" | sudo tee -a /etc/security/limits.conf

# Configure OpenSearch
cd /opt/opensearch
cat > config/opensearch.yml << 'EOF'
cluster.name: opensearch-cluster
node.name: node-1
path.data: /opt/opensearch/data
path.logs: /opt/opensearch/logs
network.host: 0.0.0.0
http.port: 9200
discovery.type: single-node
plugins.security.disabled: true
EOF

# Create directories
mkdir -p data logs

echo "Installation complete. To start OpenSearch:"
echo "cd /opt/opensearch && ./bin/opensearch"
echo "Or run in background: nohup ./bin/opensearch > logs/opensearch.log 2>&1 &"
echo "Test with: curl -X GET \"localhost:9200\""
