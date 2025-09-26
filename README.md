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

~/benchmark-env/bin/opensearch-benchmark execute-test --workload=nyc_taxis --target-hosts=10.0.0.203:9200,10.0.0.203:9201 --client-options=use_ssl:false,verify_certs:false,timeout:10 --kill-running-processes --include-tasks="index" --workload-params="bulk_indexing_clients:29,bulk_size:10000"
```

Clear the OS before each run by issuing this command to delete everything on the OS clusterm then start the benchmark:

```bash
./set_replicas.sh http://10.0.0.203:9200 nyc_taxis 1

time ~/benchmark-env/bin/opensearch-benchmark execute-test --workload=nyc_taxis --target-hosts=10.0.0.203:9200,10.0.0.203:9201 --client-options=use_ssl:false,verify_certs:false --kill-running-processes  --include-tasks="index" --workload-params="bulk_indexing_clients: 24, bulk_size: 5000"

```


