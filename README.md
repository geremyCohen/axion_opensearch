# Cluster and Node Config

## Default Parameters for OpenSearch Cluster

### Cluster Settings
| Setting | Value | Description |
|---------|-------|-------------|
| cluster.name | axion-dual | Cluster identifier |
| discovery.seed_hosts | ["127.0.0.1:9300", "127.0.0.1:9301"] | Node discovery hosts |
| cluster.initial_cluster_manager_nodes | ["node-1", "node-2"] | Initial cluster manager nodes |

### Node Settings
| Setting | Value | Description |
|---------|-------|-------------|
| network.host | 0.0.0.0 | Bind to all network interfaces |
| http.port | 9200/9201 | HTTP API ports (node1/node2) |
| transport.port | 9300/9301 | Transport layer ports (node1/node2) |
| plugins.security.disabled | true | Security plugin disabled |
| bootstrap.memory_lock | true | Lock JVM memory to prevent swapping |
| path.data | /opt/opensearch-nodeX/data | Data directory path |
| path.logs | /opt/opensearch-nodeX/logs | Log directory path |

### JVM Settings
| Setting | Value | Description |
|---------|-------|-------------|
| -Xms | 15g | Initial heap size |
| -Xmx | 15g | Maximum heap size |

### System Settings
| Setting | Value | Description |
|---------|-------|-------------|
| vm.max_map_count | 262144 | Virtual memory map count limit |
| opensearch nofile (soft/hard) | 65536 | File descriptor limits |
| opensearch nproc (soft/hard) | 4096 | Process limits |

# Install

## Local Installation

Run dual_installer.sh to install OpenSearch locally:

```bash
# Install 2-node cluster (default)
./install/dual_installer.sh install

# Install specific number of nodes (1-10)
./install/dual_installer.sh install 4

# Remove all nodes (auto-detects node count)
./install/dual_installer.sh remove
```

## Remote Installation

**Recommended Method (Copy-and-Execute):**
```bash
# Copy installer to remote host and execute
scp ./install/dual_installer.sh 10.0.0.50:/tmp/
ssh 10.0.0.50 "sudo /tmp/dual_installer.sh install 4"

# Remove all nodes from remote host (auto-detects node count)
ssh 10.0.0.50 "sudo /tmp/dual_installer.sh remove"
```

**Alternative Method (Direct Remote Execution):**
```bash
# May have SSH/permission issues with some configurations
./install/dual_installer.sh install 4 10.0.0.205
./install/dual_installer.sh remove 10.0.0.205
```

**Node Configuration:**
- Node count: 1-10 nodes per installation
- HTTP ports: 9200, 9201, 9202, 9203, etc.
- Transport ports: 9300, 9301, 9302, 9303, etc.
- Cluster name: `axion-cluster`
- **Index template**: Automatically created with optimized settings:
  - `refresh_interval: 30s` (eliminates CPU stalls from 1s default)
  - `number_of_replicas: 1` (proper data distribution)
  - `merge.scheduler.max_thread_count: 4` (controlled segment merging)
  - `translog.flush_threshold_size: 1gb` (less frequent flushes)
  - `index.codec: best_compression` (storage efficiency)

# Run

## Update Cluster Configuration

Update existing cluster settings without reinstalling:

```bash
# Update heap memory percentage only
system_memory_percent=80 ./install/dual_installer.sh update 10.0.0.50

# Update circuit breaker limits for higher indexing throughput
indices_breaker_total_limit=85% indices_breaker_request_limit=70% ./install/dual_installer.sh update 10.0.0.50

# Recommended: Update memory + breakers for maximum benchmark performance
system_memory_percent=90 indices_breaker_total_limit=85% indices_breaker_request_limit=70% indices_breaker_fielddata_limit=50% ./install/dual_installer.sh update 10.0.0.50
```

**Update Options:**
- `system_memory_percent`: Heap memory percentage (1-100)
- `indices_breaker_total_limit`: Total circuit breaker limit (e.g., 85%)
- `indices_breaker_request_limit`: Request circuit breaker limit (e.g., 70%)
- `indices_breaker_fielddata_limit`: Fielddata circuit breaker limit (e.g., 50%)

## nyc_taxis Benchmark

From the OSB, run:

```bash
# clear indices
curl -X DELETE "http://10.0.0.203:9200/nyc_taxis*"

# run nyc_taxis benchmark
# This saturates a c4a-standard-16 instance to about 95% CPU with 90 clients and bulk size of 10,000

~/benchmark-env/bin/opensearch-benchmark execute-test --workload=nyc_taxis --target-hosts=10.0.0.203:9200,10.0.0.203:9201 --client-options=use_ssl:false,verify_certs:false,timeout:60 --kill-running-processes --include-tasks="index" --workload-params="bulk_indexing_clients:90,bulk_size:10000"
```

Clear the OS before each run by issuing this command to delete everything on the OS clusterm then start the benchmark:

```bash
./set_replicas.sh http://10.0.0.203:9200 nyc_taxis 1

time ~/benchmark-env/bin/opensearch-benchmark execute-test --workload=nyc_taxis --target-hosts=10.0.0.203:9200,10.0.0.203:9201 --client-options=use_ssl:false,verify_certs:false --kill-running-processes  --include-tasks="index" --workload-params="bulk_indexing_clients: 24, bulk_size: 5000"

```


