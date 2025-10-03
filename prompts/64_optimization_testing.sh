You are an OpenSearch performance testing automation expert. Create a comprehensive bash script that executes systematic performance testing across multiple client loads and node/shard configurations.

TESTING PARAMETERS:
- Client loads: 60, 70, 80, 90, 100 (5 variations)
- Node configurations: 16, 20, 24, 28, 32 nodes (5 variations)
- Shard configurations: 16, 20, 24, 28, 32 shards (5 variations)
- Total combinations: 5 × 5 × 5 = 125 configurations
- Repetitions per combination: 4 runs for consistency verification
- Total runs: 500 runs
- Estimated duration: 83-125 hours

CLUSTER CONFIGURATION:
- Target host: IP=10.0.0.122
- Use dual_installer.sh for node/shard updates:
  bash
 nodesize=N system_memory_percent=90 indices_breaker_total_limit=85% indices_breaker_request_limit=70% indices_
breaker_fielddata_limit=50% num_of_shards=N ./install/dual_installer.sh update 10.0.0.122


OSB EXECUTION:
- Workload: nyc_taxis (index task only)
- Command template:
  bash
 ~/benchmark-env/bin/opensearch-benchmark execute-test --workload=nyc_taxis --target-hosts=10.0.0.122:
9200,10.0.0.122:9201 --client-options=use_ssl:false,verify_certs:false,timeout:60 --kill-running-processes --
include-tasks="index" --workload-params="bulk_indexing_clients:N,bulk_size:10000"



VERIFICATION & MONITORING:
- Verify OSB execution using API endpoints to check cluster indexing activity
- Monitor for completion using "[INFO] ✅ SUCCESS" message detection
- Collect minute-by-minute metrics during each run:
  - Thread pool statistics
  - I/O wait times
  - Indexing rates and latency
  - Circuit breaker usage
  - Host system resources (CPU, memory, disk)

FILE MANAGEMENT:
- Results directory: ./results/optimization/c4a-64/4k/nyc_taxis/
- OSB results naming: CLIENTS_NODES-SHARDS_REPETITION-NUM (e.g., 60_16-16_1)
- Metrics files naming: metrics_SAMPLE-NUM_REPETITION-NUM
- Save both raw OSB JSON output and parsed performance summaries
- Implement frequent compaction to prevent automatic compaction during testing

ERROR HANDLING:
- Stop immediately and report any configuration failures
- Log all errors with timestamps and configuration details
- Implement checkpointing for recovery from interruptions

CHECKPOINTING:
- Save progress after each successful run
- Enable resumption from last completed configuration
- Track completion status for all 500 runs

Create a robust script that handles this systematic testing campaign with proper error handling, progress tracking, and comprehensive metrics collection.

