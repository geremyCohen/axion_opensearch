I am working to benchmark OpenSearch performance.  I am targeting an OpenSearch (OS) dual-node on a single instance.  The install script for it is at ./install/dual_installer.sh so you can understand what it consists of.

I am generating load to it from OpenSearchBenchmark (OSB).  I use this script to geneate the load:

~/benchmark-env/bin/opensearch-benchmark execute-test --workload=nyc_taxis --target-hosts=10.0.0.203:9200,10.0.0.203:9201 --client-options=use_ssl:false,verify_certs:false --kill-running-processes  --include-tasks="index" --workload-params="bulk_indexing_clients: 24, bulk_size: 5000"

Right now, this benchmark is index-write intenseivce.  I am trying to increase indexing_clients, bulk_size, and other parameters on the OSB side until I can saturate the OS server to >= 100% CPU per core -- this is how I will know if I have saturated it.

Can you take a look at the dual_installer.sh script, my OSB command line, and tell me:

1. Am I optimized on the OpenSearch side to prevent any bottlenecks gating CPU saturation on that instance?

2. Is my command line for OSB approrpriate for this index task, to make sure I am sending everything I can to slam the OS server?

I know that I have plent of resources available on the OSB server, so I feel the bottlenecks, if any, are in my OSB script, and my OS Server settings.

The remote instance is at 10.0.0.203:9100 for node1, and same IP, port 9101 for node2, so feel free to connect to it to get values as needed.  You can also SSH/SCP to the remote node(s) to get more info as needed too.