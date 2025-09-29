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

Run dual_installer.sh to install OpenSearch 

```bash
./install/dual_installer.sh install
```

to remove, same command, but with remove

```bash
./install/dual_installer.sh remove
```

# Run

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


