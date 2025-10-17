# OpenSearch Benchmark Environment — Technical Overview

## Objective
This benchmark measures **OpenSearch 3.1.0** performance using the **nyc_taxis** workload on two single-node GCP virtual machines:  
- **Intel c4-standard-16 (x86_64, Sapphire Rapids)**  
- **Arm c4a-standard-16 (aarch64, Neoverse-V2 / Axion)**  

Both VMs are configured identically across CPU count, memory, storage, and software stack to ensure architecture-level performance comparisons.

## Executive Summary

- **Headline**: Arm (Neoverse-V2, c4a-standard-16) delivers ~**1.43× higher ingest throughput** than Intel (Sapphire Rapids, c4-standard-16) on the `nyc_taxis` workload.
- **Shared Client Count**: **16** `bulk_indexing_clients`, chosen via knee analysis (≥97% of peak, 0 rejections, iowait ≤10%).
- **Index Topology**: **6 primary shards, 0 replicas, refresh_interval=30s**; enforced by template + explicit index creation for each run.
- **Environment**: Single-node OpenSearch 3.1.0, Ubuntu 24.04, JDK 21, 31 GB heap, 1 TB pd-balanced disk.
- **Method**: Automated client sweep per architecture; then 4× full repetitions at the shared client count.


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


## 4. OpenSearch Configuration (Summary)

| Property | Value |
|-----------|--------|
| **Version** | 3.1.0 |
| **Node** | Single-node (`discovery.type: single-node`) |
| **HTTP** | `0.0.0.0:9200` |
| **Security** | Disabled |
| **Performance Analyzer** | Enabled |
| **Bootstrap Memory Lock** | true |
| **Autocreate Index** | false |
| **Disk Watermarks** | low 85%, high 90%, flood 95% |
| **Install/Control** | tarball + systemd unit |
| **Working Directory** | `/opt/opensearch-node1` |

**Key Parameters (for this study)**

| Knob | Value |
|------|-------|
| **Heap** | 31 GB (Xms=Xmx=31g) |
| **JDK** | OpenJDK 21.0.8 |
| **bulk_size** | 10,000 |
| **bulk_indexing_clients** | 16 (shared across architectures) |
| **Refresh Policy** | `index.refresh_interval=30s` throughout ingest; single `_refresh` after ingest |

> Full service/unit and YAML files are included in **Appendix A** and **Appendix B**.

## 5. Index Topology & Rationale

**Effective Settings (enforced before every run via template + explicit index creation):**

```json
{
  "index": {
    "number_of_shards": "6",
    "number_of_replicas": "0",
    "refresh_interval": "30s"
  }
}
```

**Why these values?**
- **6 shards**: balances concurrency and shard size (~25–30 GB/shard post-ingest) on a 16-vCPU, 64 GB node.
- **0 replicas**: isolates primary-shard ingest performance (no redundant writes) on single-node clusters.
- **30s refresh**: minimizes refresh/merge churn during bulk ingestion; a single `_refresh` occurs post-ingest before any search.

---



## 7. Benchmark Procedure & Parameters

**Workload & Pipeline**
- Workload: `nyc_taxis`
- Pipeline: `benchmark-only`
- Include Tasks: `index` (ingest), `search-*` (optional search phase)

**Parameters**
- `bulk_size=10,000`
- `bulk_indexing_clients=16` (shared across architectures)
- `warmup_iterations=10`
- driver timeout: 60s
- **Refresh Policy**: `index.refresh_interval=30s` throughout ingest; single `_refresh` post-ingest before any search.

**Run Discipline**
1. Before each run, delete and re-create `nyc_taxis`, and (re)apply `nyc_taxis_template` with **6 shards / 0 replicas / 30s**.
2. Run ingest (`--include-tasks=index`).
3. After ingest completes, issue a single `_refresh`.
4. Run search (`--include-tasks=search-*`) if executing the search phase.
5. Repeat as required (sweeps; then 4× final repetitions at 16 clients).

---

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


---

## 16. Bulk Client Knee Test Results and Analysis

To determine the optimal **bulk_indexing_clients** setting for the benchmark, a sweep was performed across both architectures using the automated tuning script (`tune_bulk_clients.sh`). Each test measured ingestion throughput, CPU utilization, I/O wait, and threadpool health under identical configurations.

### 16.1 Arm (c4a-standard-16, Neoverse-V2)
| Clients | Docs/s | CPU User % | Sys % | I/Owait % | Rejections | Notes |
|----------|---------|------------|--------|------------|-------------|--------|
| 12 | 336,527 | 84.3 | 4.1 | 6.0 | 0/0 | Near peak |
| **16** | **345,964** | **83.9** | **4.0** | **6.3** | **0/0** | **Knee point (chosen)** |
| 20 | 335,456 | 84.6 | 4.1 | 6.1 | 0/0 | Slight decline |
| 24 | 341,191 | 85.4 | 4.1 | 5.7 | 0/0 | Flat region |
| 32 | 349,156 | 85.3 | 4.1 | 5.8 | 0/0 | Peak |
| 40 | 342,395 | 85.5 | 4.0 | 5.7 | 0/0 | Post-plateau |
| 48 | 341,377 | 84.3 | 4.0 | 6.2 | 0/0 | Declining |
| **Peak Throughput** | **349K docs/s @ 32 clients** |
| **Chosen Client Count** | **16** (99% of peak) |
| **I/Owait Gate** | ≤ 6.3% |
| **CPU Utilization** | ~84–85% total |

**Interpretation:** The Arm instance reaches full saturation by 16–20 clients, with stable throughput through 32. The curve flattens at 16 clients, representing the knee — minimal additional gain beyond this point. The architecture demonstrates excellent CPU efficiency and no I/O or threadpool contention.

---

### 16.2 Intel (c4-standard-16, Sapphire Rapids)
| Clients | Docs/s | CPU User % | Sys % | I/Owait % | Rejections | Notes |
|----------|---------|------------|--------|------------|-------------|--------|
| **12** | **239,130** | **88.9** | **3.5** | **4.5** | **0/0** | **Knee point (chosen)** |
| 16 | 236,746 | 89.3 | 3.5 | 3.8 | 0/0 | Near plateau |
| 20 | 242,232 | 89.9 | 3.5 | 3.5 | 0/0 | Manual rerun (valid) |
| 24 | — | — | — | — | — | Failed run |
| 32 | 238,201 | 90.0 | 3.5 | 3.5 | 0/0 | Stable |
| 40 | 232,926 | 89.5 | 3.4 | 3.6 | 0/0 | Decline |
| 48 | 243,044 | 90.2 | 3.5 | 3.4 | 0/0 | Peak |
| **Peak Throughput** | **243K docs/s @ 48 clients** |
| **Chosen Client Count** | **12** (97% of peak) |
| **I/Owait Gate** | ≤ 4.5% |
| **CPU Utilization** | ~89–90% total |

**Interpretation:** The Intel 

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

---instance achieves peak throughput between 20–48 clients, plateauing beyond 12 clients. The knee occurs earlier than on Arm, with diminishing returns past 16 clients. The system remains CPU-bound, showing similar efficiency patterns but overall lower ingest throughput.

---

### 16.3 Cross-Architecture Comparison

| Metric | Arm (Neoverse-V2) | Intel (Sapphire Rapids) | Ratio (Arm ÷ Intel) |
|---------|------------------|--------------------------|----------------------|
| **Peak Throughput** | 349K docs/s | 243K docs/s | **1.43× faster** |
| **Knee Point** | 16 clients | 12 clients | — |
| **Docs/s @ Knee** | 346K | 239K | **1.45× higher** |
| **CPU Utilization** | ~84% | ~89% | — |
| **I/Owait** | 6% | 4% | — |
| **Efficiency (docs/s ÷ CPU%)** | 4.15K | 2.73K | **~1.5× more efficient** |
| **Rejections / Stability** | 0 / 0 | 0 / 0 | Both clean |

---

### 16.4 Benchmark Configuration Decision

Based on the results of the knee analysis, the following configuration was selected for all formal benchmarks:

| Parameter | Value |
|------------|--------|
| **bulk_indexing_clients** | **16** (common to both) |
| **bulk_size** | 10,000 |
| **refresh_interval** | 30s |
| **number_of_shards** | 6 |
| **number_of_replicas** | 0 |
| **Cluster Nodes** | 1 (single-node) |
| **Workload** | `nyc_taxis` (index phase) |

This shared configuration ensures identical concurrency and index topology for both platforms, enabling a fair apples-to-apples comparison. Additionally, the per-architecture maxima (Arm @ 32 clients, Intel @ 20 clients) will be referenced in capacity scaling analysis for peak throughput discussion.

---

**Summary:**  
- Arm (Neoverse-V2) outperforms Intel (Sapphire Rapids) by **~43–45%** in indexing throughput at equivalent concurrency and system utilization.  
- Both exhibit balanced CPU/I/O characteristics, with no threadpool rejections or GC instability.  
- `bulk_indexing_clients=16` is chosen for all subsequent benchmark phases (ingest and search) to represent the shared performance knee across architectures.



---
---

## Appendix A — Systemd Override (opensearch.service)

**File:** `/etc/systemd/system/opensearch.service.d/override.conf`
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

## Appendix B — OpenSearch YAML Configuration

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
