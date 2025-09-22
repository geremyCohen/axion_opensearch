# OpenSearch Benchmark Commands

## URLs
- OpenSearch: http://localhost:9200
- OpenSearch Cluster Health: http://localhost:9200/_cluster/health?pretty
- OpenSearch Indices: http://localhost:9200/_cat/indices?v
- OpenSearch Nodes: http://localhost:9200/_cat/nodes?v
- OpenSearch Stats: http://localhost:9200/_stats?pretty
- OpenSearch Benchmark: https://github.com/opensearch-project/opensearch-benchmark
- OpenSearch Workloads: https://github.com/opensearch-project/opensearch-benchmark-workloads

## Run Benchmark
```bash
~/benchmark-env/bin/opensearch-benchmark run --workload=nyc_taxis --target-hosts=localhost:9200 --client-options=use_ssl:false,verify_certs:false
```

## Kill Existing Benchmark
```bash
pkill -f opensearch-benchmark
```

## Monitor Benchmark
```bash
# Check cluster health
curl localhost:9200/_cluster/health?pretty

# Monitor indices
curl localhost:9200/_cat/indices?v

# View logs
tail -f ~/.benchmark/logs/opensearch-benchmark.log

# System resources
htop
```

## Clean Up & Restart
```bash
# Kill benchmark
pkill -f opensearch-benchmark

# Clean up data (optional)
curl -X DELETE "localhost:9200/nyc_taxis*"

# Restart benchmark
~/benchmark-env/bin/opensearch-benchmark run --workload=nyc_taxis --target-hosts=localhost:9200 --client-options=use_ssl:false,verify_certs:false
```
