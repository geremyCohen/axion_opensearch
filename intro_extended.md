# OpenSearch Benchmark Environment — Technical Overview

## Objective
This benchmark measures **OpenSearch 3.1.0** performance using the **nyc_taxis** workload on two single-node GCP virtual machines:  
- **Intel c4-standard-16 (x86_64)**  
- **Arm c4a-standard-16 (aarch64 / Axion)**  

Both VMs are configured identically across CPU count, memory, storage, and software stack to ensure architecture-level performance comparisons.

---

## 1. Virtual Machine Specifications

| Component | Setting |
|------------|----------|
| **Machine Type** | `c4a-standard-16` (Arm) / `c4-standard-16` (Intel) |
| **vCPUs** | 16 |
| **RAM** | 64 GB |
| **Storage** | 1 TB `pd-balanced` persistent disk (identical configuration on both) |
| **Network** | 10 Gbps network throughput (GCP default for c4/c4a) |
| **Operating System** | Ubuntu 24.04 LTS |
| **Kernel** | 6.14.0-1017-gcp |
| **Architecture** | `aarch64` (Arm) / `x86_64` (Intel) |
| **NUMA** | Single NUMA node |
| **Hypervisor** | GCP KVM |
| **Threading** | 1 thread per core |

---

## 2. OS and Kernel Configuration

| Parameter | Value / Action |
|------------|----------------|
| **Swapping** | Disabled (`swapoff -a`; swap entries commented in `/etc/fstab`) |
| **Memory Map Limit** | `vm.max_map_count = 262144` |
| **Transparent Huge Pages** | Default (enabled, no custom tuning) |
| **Open File Limit** | `LimitNOFILE = 65536` |
| **Process Limit** | `LimitNPROC = 65536` |
| **Memory Lock** | `LimitMEMLOCK = infinity` |
| **TasksMax** | `infinity` |
| **Networking** | Default GCP VPC (internal IP access only) |

---

## 3. Java Runtime Environment

| Property | Setting |
|-----------|----------|
| **Version** | OpenJDK 21.0.8 (system installation) |
| **Path** | `/usr/lib/jvm/java-21-openjdk-{arm64|amd64}` |
| **Usage** | Set via `Environment=OPENSEARCH_JAVA_HOME` in systemd |
| **GC Algorithm** | G1GC |
| **GC Parameters** | `-XX:+UseG1GC -XX:G1ReservePercent=15 -XX:InitiatingHeapOccupancyPercent=30` |
| **Heap Size** | 31 GB (Xms = Xmx = 31g) |
| **MaxDirectMemorySize** | ~16 GB |
| **Other JVM Flags** | `+AlwaysPreTouch`, `+ExitOnOutOfMemoryError`, `+HeapDumpOnOutOfMemoryError` |
| **GC Logging** | Enabled: `/var/log/opensearch/gc.log` |

---

## 4. OpenSearch Configuration

| Property | Value |
|-----------|--------|
| **Version** | 3.1.0 |
| **Node Count** | 1 (single-node cluster) |
| **Cluster Name** | `osb-nyct-arm` / `osb-nyct-intel` |
| **Node Name** | `os-node` |
| **Discovery Type** | `single-node` |
| **Network Host** | `0.0.0.0` |
| **HTTP Port** | 9200 |
| **Security Plugin** | Disabled |
| **Performance Analyzer** | Enabled |
| **Bootstrap Memory Lock** | `true` |
| **Autocreate Index** | Disabled |
| **Disk Watermarks** | low 85%, high 90%, flood 95% |
| **Distribution Type** | tarball install, managed via systemd |
| **Working Directory** | `/opt/opensearch-node1` |

---

## 5. JVM & Systemd Configuration

**Systemd Override:** `/etc/systemd/system/opensearch.service.d/override.conf`
```ini
[Service]
User=opensearch
Group=opensearch
Type=simple
Restart=always
RestartSec=10
WorkingDirectory=/opt/opensearch-node1
ExecStart=
ExecStart=/opt/opensearch-node1/bin/opensearch
Environment=OPENSEARCH_JAVA_HOME=/usr/lib/jvm/java-21-openjdk-arm64
Environment=OPENSEARCH_PATH_CONF=/opt/opensearch-node1/config
LimitNOFILE=65536
LimitNPROC=65536
LimitMEMLOCK=infinity
TasksMax=infinity
```

---

## 6. OpenSearch YAML Configuration

**File:** `/opt/opensearch-node1/config/opensearch.yml`

```yaml
cluster.name: osb-nyct-arm   # or osb-nyct-intel
node.name: os-node
discovery.type: single-node
network.host: 0.0.0.0
http.port: 9200
bootstrap.memory_lock: true
plugins:
  security:
    disabled: true
  performanceanalyzer:
    enabled: true
index.number_of_shards: 6
index.number_of_replicas: 0
index.refresh_interval: 30s
action.auto_create_index: false
cluster.routing.allocation.disk.watermark.low: 85%
cluster.routing.allocation.disk.watermark.high: 90%
cluster.routing.allocation.disk.watermark.flood_stage: 95%
```

---

## 7. Index Template Configuration

**Index Template:** `nyc_taxis_template`
```json
{
  "index": {
    "number_of_shards": "6",
    "number_of_replicas": "0",
    "refresh_interval": "30s"
  }
}
```
The template ensures consistent shard and refresh parameters even if the benchmark re-creates the index.

---

## 8. Cluster Health Verification

| Metric | Result |
|---------|--------|
| **Cluster Health** | Green |
| **Active Primary Shards** | 6 (nyc_taxis) + 1 system shard |
| **Replicas** | 0 |
| **Unassigned Shards** | 0 |
| **Node Count** | 1 |
| **Process Count** | 1 OpenSearch process |

---

## 9. OpenSearch Benchmark Configuration

| Parameter | Value |
|------------|--------|
| **Workload** | `nyc_taxis` |
| **Pipeline** | `benchmark-only` |
| **Include Tasks** | `index` (ingest phase) / `search-*` (search phase) |
| **Bulk Size** | 10,000 |
| **Bulk Clients** | 40 |
| **Warmup Iterations** | 10 |
| **Timeout** | 60 seconds |
| **Refresh Interval During Run** | Constant 30s (no dynamic flips) |
| **Cluster Preparation** | Index and template created before workload; no runtime `curl` calls |

---

## 10. Data Visibility and Search Configuration
After ingest:
- A manual `_refresh` is triggered **once** to make data visible.  
- No further refresh or replica changes occur during search benchmarking.  
- Caches remain stable (no invalidation due to refresh).

---

## 11. Validation Checks Performed
Before each benchmark:
- Cluster health = green  
- One OpenSearch process active  
- `Xms=Xmx=31g` heap verified  
- Template and index settings verified:
  ```bash
  {
    "number_of_shards": "6",
    "number_of_replicas": "0",
    "refresh_interval": "30s"
  }
  ```

---

## 12. Summary

The testbed represents a **controlled, single-node OpenSearch environment** optimized for CPU and I/O benchmarking across architectures.  
No network, replica, or multi-node distribution effects are introduced, ensuring all results reflect **pure single-node ingestion and query performance** under identical heap, JDK, and OS constraints.

---

## 13. Benchmark Procedure

### Step 1 — Cluster Preparation
1. The index template (`nyc_taxis_template`) is applied with 6 shards, 0 replicas, and 30s refresh interval.  
2. The index `nyc_taxis` is created (or re-created) cleanly before each benchmark iteration.  
3. Cluster health is verified to be green before proceeding.

### Step 2 — Ingest Phase
- OSB runs with `--include-tasks="index"`.
- 40 concurrent bulk clients (`bulk_indexing_clients=40`), each submitting 10k document batches.
- Auto-refresh remains at 30s for minimal ingest overhead.
- Once ingestion completes, a single `_refresh` ensures full visibility of documents.

### Step 3 — Search Phase
- OSB runs with `--include-tasks="search-*"` using the same workload.
- No cluster configuration changes occur between ingest and search.
- Cache warming runs can be optionally performed before timing search workloads.

### Step 4 — Validation
- Post-ingest and post-search health checks confirm:
  - Green cluster status
  - 6 primary shards, 0 replicas
  - No unassigned shards
  - Heap usage and GC logs captured

---

## 14. Result Metrics Collected

| Metric | Description |
|---------|--------------|
| **Throughput (ops/s)** | Indexing and query throughput measured by OSB. |
| **Latency (p50 / p90 / p99)** | Collected per task (index and search). |
| **CPU Utilization** | Collected via OpenSearch Performance Analyzer (and host-level telemetry). |
| **Memory Utilization** | JVM heap and resident memory usage. |
| **GC Metrics** | Pause times, frequency, and survivor promotion stats from `gc.log`. |
| **Storage I/O** | Disk read/write throughput (monitored via `iostat`). |
| **Network I/O** | Interface-level throughput; minimal for single-node setup. |
| **Index Size** | Total on-disk index size after ingestion (from `_stats/store`). |
| **Document Count** | Final document count (target ≈165M for full `nyc_taxis` workload). |

---

**All benchmark runs are repeated 4 times per architecture (Intel and Arm).**  
Results are compared based on normalized throughput, latency percentiles, and system-level efficiency (CPU per op).


---

## 15. Client Count Selection Methodology

To choose `bulk_indexing_clients` fairly for both Intel and Arm, we ran an automated sweep and selected the **smallest** client count achieving **≥ 97%** of each node’s peak ingest throughput **without** violating quality gates.

**Procedure**
1. Fix `bulk_size=10,000` and other workload params; keep index at 6 primaries, 0 replicas, `refresh_interval=30s`.
2. Sweep client counts (e.g., `8,12,16,20,24,32,40,48`) with ingest-only runs.
3. For each trial, collect:
   - Ingest throughput (docs/s),
   - Tail latency (p99) if available,
   - Threadpool rejections (`write`/`bulk`),
   - CPU utilization (user/sys) and **iowait** via `mpstat`.
4. Compute the knee:
   - Let **peak** be the maximum docs/s observed.
   - Set **target = 0.97 × peak**.
   - Choose the **smallest** client count with `docs/s ≥ target`, **0 rejections**, and average `iowait ≤ 10%`.

**Outputs**
- Per-arch CSV (`tune_results.csv`) with one row per client count.
- A recommendation printed at the end (both **apples-to-apples** shared value and per-arch **capacity** value can be derived).

This method avoids anchoring on CPU percentages alone and instead uses the **throughput knee with quality gates**, yielding a robust, comparable client count.
