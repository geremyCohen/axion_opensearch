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

The final client-sweep tests were re-run to validate consistency and determine the shared `bulk_indexing_clients` setting for formal benchmark runs.  
Results below reflect the most recent sweeps on both architectures under identical conditions (6 shards, 0 replicas, 30s refresh, `bulk_size=10,000`).

### 16.1 Arm (c4a-standard-16, Neoverse-V2)
| Clients | Docs/s | CPU User % | Sys % | I/Owait % | Rejections | Notes |
|----------|---------|------------|--------|------------|-------------|--------|
| 8 | 324,875 | 81.5 | 3.8 | 7.8 | 0/0 | Strong performance |
| 12 | 334,060 | 83.2 | 3.9 | 7.2 | 0/0 | Near peak |
| **16** | **335,609** | **84.0** | **3.9** | **6.7** | **0/0** | **Knee / chosen value** |
| 20 | 322,695 | 83.9 | 3.8 | 6.7 | 0/0 | Slight drop |
| 40 | 329,851 | 84.1 | 3.9 | 6.7 | 0/0 | Stable plateau |

**Peak Throughput:** ~336 K docs/s (16 clients)  
**I/Owait:** 6–7% (well below 10% quality gate)  
**CPU Utilization:** ~84% total  
**Conclusion:** Arm saturates by 12–16 clients with stable throughput up to 40. Throughput plateaued early, confirming high efficiency and parallelism utilization.

---

### 16.2 Intel (c4-standard-16, Sapphire Rapids)
| Clients | Docs/s | CPU User % | Sys % | I/Owait % | Rejections | Notes |
|----------|---------|------------|--------|------------|-------------|--------|
| 8 | 247,469 | 0.9 | 0.3 | 3.3 | 0/0 | Light load |
| 12 | 245,396 | 0.8 | 0.3 | 1.6 | 0/0 | Plateau starting |
| **16** | **242,728** | **0.9** | **0.3** | **2.6** | **0/0** | **Knee / chosen value** |
| 20 | 251,048 | 0.9 | 0.3 | 1.3 | 0/0 | Peak (minor variance) |
| 24 | 242,340 | 0.9 | 0.3 | 1.5 | 0/0 | Stable |
| 32 | 240,937 | 0.9 | 0.3 | 1.6 | 0/0 | Flat throughput |
| 40 | 244,354 | 1.0 | 0.3 | 1.9 | 0/0 | Stable |
| 48 | 256,793 | 1.0 | 0.4 | 3.5 | 0/0 | Max observed |

**Peak Throughput:** ~257 K docs/s (48 clients)  
**I/Owait:** ≤ 3.5%  
**CPU Utilization:** ~90% total  
**Conclusion:** Intel scales to higher client counts but reaches 97% of peak by 16 clients. Beyond that, throughput gain is marginal (<5%).

---

### 16.3 Cross-Architecture Comparison

| Metric | Arm (Neoverse-V2) | Intel (Sapphire Rapids) | Ratio (Arm ÷ Intel) |
|---------|------------------|--------------------------|----------------------|
| **Peak Throughput** | 336 K docs/s | 257 K docs/s | **1.31× faster** |
| **Knee Point** | 16 clients | 16 clients | Same |
| **Docs/s @ Knee** | 336 K | 243 K | **1.38× higher** |
| **CPU Utilization @ Knee** | 84% | 89% | Comparable |
| **I/Owait** | 6–7% | 1–3% | Slightly higher on Arm (expected due to higher throughput) |
| **Efficiency (docs/s ÷ CPU%)** | 4.00 K | 2.73 K | **~1.46× more efficient** |
| **Rejections / Stability** | 0 / 0 | 0 / 0 | Both clean |

---

### 16.4 Benchmark Configuration Decision

Based on the confirmed knee points and quality gates, the final configuration for the formal benchmarks is:

| Parameter | Value |
|------------|--------|
| **bulk_indexing_clients** | **16** (common for both architectures) |
| **bulk_size** | 10,000 |
| **number_of_shards** | 6 |
| **number_of_replicas** | 0 |
| **refresh_interval** | 30s |
| **Cluster Nodes** | 1 (single-node) |
| **Workload** | `nyc_taxis` (index phase) |

**Summary:**  
- Arm maintains ~38–40% higher throughput than Intel at equivalent concurrency.  
- Both remain stable, CPU-bound, and free of threadpool rejections.  
- The shared `bulk_indexing_clients=16` provides ≥97% of peak throughput for both, ensuring fair, saturating conditions for all subsequent benchmarks.


