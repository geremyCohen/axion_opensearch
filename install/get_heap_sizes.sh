curl -s "http://127.0.0.1:9200/_nodes/jvm?filter_path=nodes.*.name,nodes.*.jvm.mem.heap_max_in_bytes" | jq .
