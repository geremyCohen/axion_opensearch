#!/usr/bin/env python3
import os
import sys
import json
import glob
from pathlib import Path

def extract_metrics(json_file):
    with open(json_file, 'r') as f:
        data = json.load(f)
    
    results = data.get('results', {})
    op_metrics_list = results.get('op_metrics', [])
    
    # System-wide metrics (convert from ms to minutes where needed, bytes to GB/MB)
    system_metrics = {
        # Indexing metrics
        'total_time': results.get('total_time', 0) / 60000,  # ms to min
        'total_time_min': results.get('total_time_per_shard', {}).get('min', 0) / 60000,
        'total_time_median': results.get('total_time_per_shard', {}).get('median', 0) / 60000,
        'total_time_max': results.get('total_time_per_shard', {}).get('max', 0) / 60000,
        
        # Indexing throttle metrics
        'indexing_throttle_time': results.get('indexing_throttle_time', 0) / 60000,
        'indexing_throttle_time_min': results.get('indexing_throttle_time_per_shard', {}).get('min', 0) / 60000,
        'indexing_throttle_time_median': results.get('indexing_throttle_time_per_shard', {}).get('median', 0) / 60000,
        'indexing_throttle_time_max': results.get('indexing_throttle_time_per_shard', {}).get('max', 0) / 60000,
        
        # Merge metrics
        'merge_time': results.get('merge_time', 0) / 60000,
        'merge_time_min': results.get('merge_time_per_shard', {}).get('min', 0) / 60000,
        'merge_time_median': results.get('merge_time_per_shard', {}).get('median', 0) / 60000,
        'merge_time_max': results.get('merge_time_per_shard', {}).get('max', 0) / 60000,
        'merge_count': results.get('merge_count', 0),
        
        # Merge throttle metrics
        'merge_throttle_time': results.get('merge_throttle_time', 0) / 60000,
        'merge_throttle_time_min': results.get('merge_throttle_time_per_shard', {}).get('min', 0) / 60000,
        'merge_throttle_time_median': results.get('merge_throttle_time_per_shard', {}).get('median', 0) / 60000,
        'merge_throttle_time_max': results.get('merge_throttle_time_per_shard', {}).get('max', 0) / 60000,
        
        # Refresh metrics
        'refresh_time': results.get('refresh_time', 0) / 60000,
        'refresh_time_min': results.get('refresh_time_per_shard', {}).get('min', 0) / 60000,
        'refresh_time_median': results.get('refresh_time_per_shard', {}).get('median', 0) / 60000,
        'refresh_time_max': results.get('refresh_time_per_shard', {}).get('max', 0) / 60000,
        'refresh_count': results.get('refresh_count', 0),
        
        # Flush metrics
        'flush_time': results.get('flush_time', 0) / 60000,
        'flush_time_min': results.get('flush_time_per_shard', {}).get('min', 0) / 60000,
        'flush_time_median': results.get('flush_time_per_shard', {}).get('median', 0) / 60000,
        'flush_time_max': results.get('flush_time_per_shard', {}).get('max', 0) / 60000,
        'flush_count': results.get('flush_count', 0),
        
        # GC metrics
        'young_gc_time': results.get('young_gc_time', 0) / 1000,  # ms to s
        'young_gc_count': results.get('young_gc_count', 0),
        'old_gc_time': results.get('old_gc_time', 0) / 1000,  # ms to s
        'old_gc_count': results.get('old_gc_count', 0),
        
        # Storage metrics
        'store_size': results.get('store_size', 0) / (1024**3),  # bytes to GB
        'translog_size': results.get('translog_size', 0) / (1024**3),  # bytes to GB
        'segment_count': results.get('segment_count', 0),
        
        # Memory metrics
        'memory_segments': results.get('memory_segments', 0) / (1024**2),  # bytes to MB
        'memory_doc_values': results.get('memory_doc_values', 0) / (1024**2),
        'memory_terms': results.get('memory_terms', 0) / (1024**2),
        'memory_norms': results.get('memory_norms', 0) / (1024**2),
        'memory_points': results.get('memory_points', 0) / (1024**2),
        'memory_stored_fields': results.get('memory_stored_fields', 0) / (1024**2)
    }
    
    # Task-specific metrics - extract all tasks
    tasks_metrics = {}
    for op_metric in op_metrics_list:
        task_name = op_metric.get('task', 'unknown')
        task_metrics = {
            # Throughput metrics
            'throughput_min': op_metric.get('throughput', {}).get('min', 0),
            'throughput_mean': op_metric.get('throughput', {}).get('mean', 0),
            'throughput_median': op_metric.get('throughput', {}).get('median', 0),
            'throughput_max': op_metric.get('throughput', {}).get('max', 0),
            
            # Latency percentiles
            'latency_p50': op_metric.get('latency', {}).get('50_0', 0),
            'latency_p90': op_metric.get('latency', {}).get('90_0', 0),
            'latency_p99': op_metric.get('latency', {}).get('99_0', 0),
            'latency_p99_9': op_metric.get('latency', {}).get('99_9', 0),
            'latency_p100': op_metric.get('latency', {}).get('100_0', 0),
            'latency_mean': op_metric.get('latency', {}).get('mean', 0),
            
            # Service time percentiles
            'service_time_p50': op_metric.get('service_time', {}).get('50_0', 0),
            'service_time_p90': op_metric.get('service_time', {}).get('90_0', 0),
            'service_time_p99': op_metric.get('service_time', {}).get('99_0', 0),
            'service_time_p99_9': op_metric.get('service_time', {}).get('99_9', 0),
            'service_time_p100': op_metric.get('service_time', {}).get('100_0', 0),
            'service_time_mean': op_metric.get('service_time', {}).get('mean', 0),
            
            # Client processing time percentiles
            'client_processing_time_p50': op_metric.get('client_processing_time', {}).get('50_0', 0),
            'client_processing_time_p90': op_metric.get('client_processing_time', {}).get('90_0', 0),
            'client_processing_time_p99': op_metric.get('client_processing_time', {}).get('99_0', 0),
            'client_processing_time_p99_9': op_metric.get('client_processing_time', {}).get('99_9', 0),
            'client_processing_time_p100': op_metric.get('client_processing_time', {}).get('100_0', 0),
            'client_processing_time_mean': op_metric.get('client_processing_time', {}).get('mean', 0),
            
            # Processing time percentiles
            'processing_time_p50': op_metric.get('processing_time', {}).get('50_0', 0),
            'processing_time_p90': op_metric.get('processing_time', {}).get('90_0', 0),
            'processing_time_p99': op_metric.get('processing_time', {}).get('99_0', 0),
            'processing_time_p99_9': op_metric.get('processing_time', {}).get('99_9', 0),
            'processing_time_p100': op_metric.get('processing_time', {}).get('100_0', 0),
            'processing_time_mean': op_metric.get('processing_time', {}).get('mean', 0),
            
            # Other metrics
            'error_rate': op_metric.get('error_rate', 0),
            'duration': op_metric.get('duration', 0) / 1000  # ms to seconds
        }
        tasks_metrics[task_name] = task_metrics
    
    return system_metrics, tasks_metrics

def generate_html(data_dir):
    json_files = glob.glob(f"{data_dir}/**/*.json", recursive=True)
    json_files = [f for f in json_files if not f.endswith('_summary.json')]
    
    configs = []
    system_data = {}
    all_tasks_data = {}
    
    for json_file in json_files:
        # Extract config from path: c4a-72/4k -> "c4a-72 4k"
        path_parts = Path(json_file).parts
        instance_type = None
        page_size = None
        
        for i, part in enumerate(path_parts):
            if part.startswith('c4'):
                instance_type = part
                if i + 1 < len(path_parts):
                    page_size = path_parts[i + 1]
                break
        
        config_name = f"{instance_type} {page_size}" if instance_type and page_size else Path(json_file).parent.name
        system_metrics, tasks_metrics = extract_metrics(json_file)
        
        configs.append(config_name)
        
        # System metrics
        for key, value in system_metrics.items():
            if key not in system_data:
                system_data[key] = []
            system_data[key].append(value)
        
        # Task metrics - organize by task name
        for task_name, task_metrics in tasks_metrics.items():
            if task_name not in all_tasks_data:
                all_tasks_data[task_name] = {}
            
            for key, value in task_metrics.items():
                if key not in all_tasks_data[task_name]:
                    all_tasks_data[task_name][key] = []
                all_tasks_data[task_name][key].append(value)
    
    # Generate HTML sections for each task
    task_sections = ""
    task_scripts = ""
    
    for task_name, task_data in all_tasks_data.items():
        task_sections += f'''
    <div class="section">
        <h2>Task: {task_name.title()}</h2>
        
        <div class="chart-row">
            <div class="chart-half">
                <div id="{task_name}-throughput-chart"></div>
                <div id="{task_name}-throughput-table"></div>
            </div>
            <div class="chart-half">
                <div id="{task_name}-latency-chart"></div>
                <div id="{task_name}-latency-table"></div>
            </div>
        </div>
        
        <div class="chart-row">
            <div class="chart-half">
                <div id="{task_name}-service-time-chart"></div>
                <div id="{task_name}-service-time-table"></div>
            </div>
            <div class="chart-half">
                <div id="{task_name}-duration-chart"></div>
                <div id="{task_name}-duration-table"></div>
            </div>
        </div>
    </div>'''
        
        # Generate JavaScript for each task
        task_scripts += f'''
        // {task_name} - Throughput Distribution
        const {task_name.replace('-', '_')}ThroughputData = [];
        for (let i = 0; i < uniqueConfigs.length; i++) {{
            const configIndices = configs.map((c, idx) => c === uniqueConfigs[i] ? idx : -1).filter(idx => idx !== -1);
            const values = configIndices.map(idx => [{task_data.get('throughput_min', [])}[idx], {task_data.get('throughput_median', [])}[idx], {task_data.get('throughput_mean', [])}[idx], {task_data.get('throughput_max', [])}[idx]]).flat();
            {task_name.replace('-', '_')}ThroughputData.push({{
                y: values,
                type: 'box',
                name: uniqueConfigs[i],
                boxpoints: false
            }});
        }}

        Plotly.newPlot('{task_name}-throughput-chart', {task_name.replace('-', '_')}ThroughputData, {{
            title: '{task_name.title()} Throughput Distribution (docs/s)',
            xaxis: {{ title: 'Configuration' }},
            yaxis: {{ title: 'Throughput (docs/s)' }}
        }});

        // {task_name} - Latency percentiles
        const {task_name.replace('-', '_')}LatencyData = [];
        for (let i = 0; i < uniqueConfigs.length; i++) {{
            const configIndices = configs.map((c, idx) => c === uniqueConfigs[i] ? idx : -1).filter(idx => idx !== -1);
            const p50Values = configIndices.map(idx => {task_data.get('latency_p50', [])}[idx]);
            const p90Values = configIndices.map(idx => {task_data.get('latency_p90', [])}[idx]);
            
            {task_name.replace('-', '_')}LatencyData.push({{
                y: p50Values,
                type: 'box',
                name: uniqueConfigs[i] + ' P50',
                boxpoints: 'all',
                marker: {{ color: '#3498db' }}
            }});
            
            {task_name.replace('-', '_')}LatencyData.push({{
                y: p90Values,
                type: 'box',
                name: uniqueConfigs[i] + ' P90',
                boxpoints: 'all',
                marker: {{ color: '#e74c3c' }}
            }});
        }}

        Plotly.newPlot('{task_name}-latency-chart', {task_name.replace('-', '_')}LatencyData, {{
            title: '{task_name.title()} Latency Percentiles (ms)',
            xaxis: {{ title: 'Configuration & Percentile' }},
            yaxis: {{ title: 'Latency (ms)' }}
        }});

        // {task_name} - Duration
        const {task_name.replace('-', '_')}DurationData = [];
        for (let rep = 1; rep <= 4; rep++) {{
            const repIndices = configs.map((c, idx) => (idx % 4) === (rep - 1) ? idx : -1).filter(idx => idx !== -1);
            {task_name.replace('-', '_')}DurationData.push({{
                x: repIndices.map(idx => configs[idx]),
                y: repIndices.map(idx => {task_data.get('duration', [])}[idx]),
                type: 'bar',
                name: `Rep ${{rep}}`,
                marker: {{ color: `hsl(${{rep * 80}}, 70%, 50%)` }}
            }});
        }}

        Plotly.newPlot('{task_name}-duration-chart', {task_name.replace('-', '_')}DurationData, {{
            title: '{task_name.title()} Duration by Rep (seconds)',
            xaxis: {{ title: 'Configuration' }},
            yaxis: {{ title: 'Duration (seconds)' }},
            barmode: 'group'
        }});
        '''
    
    html_content = f'''<!DOCTYPE html>
<html>
<head>
    <title>Combined System & Task Metrics Dashboard</title>
    <script src="https://cdn.plot.ly/plotly-latest.min.js"></script>
    <style>
        body {{ font-family: Arial, sans-serif; margin: 20px; }}
        .chart-container {{ margin: 30px 0; }}
        .chart-row {{ display: flex; gap: 20px; }}
        .chart-half {{ flex: 1; }}
        .chart-third {{ flex: 1; }}
        h1 {{ color: #2c3e50; }}
        h2 {{ color: #34495e; border-bottom: 2px solid #ecf0f1; padding-bottom: 10px; }}
        .section {{ background: #f8f9fa; padding: 20px; margin: 20px 0; border-radius: 8px; }}
        .data-table {{ margin-top: 15px; width: 100%; border-collapse: collapse; font-size: 12px; }}
        .data-table th, .data-table td {{ border: 1px solid #ddd; padding: 8px; text-align: center; }}
        .data-table th {{ background-color: #f2f2f2; font-weight: bold; }}
        .data-table tr:nth-child(even) {{ background-color: #f9f9f9; }}
    </style>
</head>
<body>
    <h1>OpenSearch Benchmark Performance Dashboard</h1>
    
    <div class="section">
        <h2>System-Wide Metrics</h2>
        
        <div class="chart-row">
            <div class="chart-half">
                <div id="indexing-time-chart"></div>
                <div id="indexing-time-table"></div>
            </div>
            <div class="chart-half">
                <div id="merge-time-chart"></div>
                <div id="merge-time-table"></div>
            </div>
        </div>
        
        <div class="chart-row">
            <div class="chart-half">
                <div id="refresh-flush-chart"></div>
                <div id="refresh-flush-table"></div>
            </div>
            <div class="chart-half">
                <div id="throttle-chart"></div>
                <div id="throttle-table"></div>
            </div>
        </div>
        
        <div class="chart-row">
            <div class="chart-third">
                <div id="gc-chart"></div>
                <div id="gc-table"></div>
            </div>
            <div class="chart-third">
                <div id="storage-chart"></div>
                <div id="storage-table"></div>
            </div>
            <div class="chart-third">
                <div id="memory-chart"></div>
                <div id="memory-table"></div>
            </div>
        </div>
        
        <div id="counts-chart"></div>
        <div id="counts-table"></div>
    </div>
    
    {task_sections}

    <script>
        const configs = {configs};
        const uniqueConfigs = [...new Set(configs)];
        
        // System-wide charts (existing code)
        const indexingTimeData = [];
        for (let i = 0; i < uniqueConfigs.length; i++) {{
            const configIndices = configs.map((c, idx) => c === uniqueConfigs[i] ? idx : -1).filter(idx => idx !== -1);
            const values = configIndices.map(idx => [{system_data.get('total_time_min', [])}[idx], {system_data.get('total_time_median', [])}[idx], {system_data.get('total_time_max', [])}[idx]]).flat();
            indexingTimeData.push({{
                y: values,
                type: 'box',
                name: uniqueConfigs[i],
                boxpoints: false
            }});
        }}

        Plotly.newPlot('indexing-time-chart', indexingTimeData, {{
            title: 'Indexing Time Distribution (minutes)',
            xaxis: {{ title: 'Configuration' }},
            yaxis: {{ title: 'Time (minutes)' }}
        }});

        // Merge time
        const mergeTimeData = [];
        for (let i = 0; i < uniqueConfigs.length; i++) {{
            const configIndices = configs.map((c, idx) => c === uniqueConfigs[i] ? idx : -1).filter(idx => idx !== -1);
            const values = configIndices.map(idx => [{system_data.get('merge_time_min', [])}[idx], {system_data.get('merge_time_median', [])}[idx], {system_data.get('merge_time_max', [])}[idx]]).flat();
            mergeTimeData.push({{
                y: values,
                type: 'box',
                name: uniqueConfigs[i],
                boxpoints: false
            }});
        }}

        Plotly.newPlot('merge-time-chart', mergeTimeData, {{
            title: 'Merge Time Distribution (minutes)',
            xaxis: {{ title: 'Configuration' }},
            yaxis: {{ title: 'Time (minutes)' }}
        }});

        // Refresh time
        const refreshData = [];
        for (let rep = 1; rep <= 4; rep++) {{
            const repIndices = configs.map((c, idx) => (idx % 4) === (rep - 1) ? idx : -1).filter(idx => idx !== -1);
            refreshData.push({{
                x: repIndices.map(idx => configs[idx]),
                y: repIndices.map(idx => {system_data.get('refresh_time', [])}[idx]),
                type: 'bar',
                name: `Rep ${{rep}}`,
                marker: {{ color: `hsl(${{rep * 80}}, 70%, 50%)` }}
            }});
        }}

        Plotly.newPlot('refresh-flush-chart', refreshData, {{
            title: 'Refresh Time by Rep (minutes)',
            xaxis: {{ title: 'Configuration' }},
            yaxis: {{ title: 'Time (minutes)' }},
            barmode: 'group'
        }});

        // Throttle times
        const throttleData = [
            {{
                x: configs,
                y: {system_data.get('indexing_throttle_time', [])},
                type: 'bar',
                name: 'Indexing Throttle',
                marker: {{ color: '#e74c3c' }}
            }},
            {{
                x: configs,
                y: {system_data.get('merge_throttle_time', [])},
                type: 'bar',
                name: 'Merge Throttle',
                marker: {{ color: '#c0392b' }}
            }}
        ];

        Plotly.newPlot('throttle-chart', throttleData, {{
            title: 'Throttle Times (minutes)',
            xaxis: {{ title: 'Configuration' }},
            yaxis: {{ title: 'Time (minutes)' }},
            barmode: 'group'
        }});

        // GC time
        const gcData = [];
        for (let rep = 1; rep <= 4; rep++) {{
            const repIndices = configs.map((c, idx) => (idx % 4) === (rep - 1) ? idx : -1).filter(idx => idx !== -1);
            gcData.push({{
                x: repIndices.map(idx => configs[idx]),
                y: repIndices.map(idx => {system_data.get('young_gc_time', [])}[idx]),
                type: 'bar',
                name: `Rep ${{rep}}`,
                marker: {{ color: `hsl(${{rep * 80}}, 70%, 50%)` }}
            }});
        }}

        Plotly.newPlot('gc-chart', gcData, {{
            title: 'Young GC Time by Rep (seconds)',
            xaxis: {{ title: 'Configuration' }},
            yaxis: {{ title: 'Time (seconds)' }},
            barmode: 'group'
        }});

        // Storage
        const storageData = [];
        for (let rep = 1; rep <= 4; rep++) {{
            const repIndices = configs.map((c, idx) => (idx % 4) === (rep - 1) ? idx : -1).filter(idx => idx !== -1);
            storageData.push({{
                x: repIndices.map(idx => configs[idx]),
                y: repIndices.map(idx => {system_data.get('store_size', [])}[idx]),
                type: 'bar',
                name: `Rep ${{rep}}`,
                marker: {{ color: `hsl(${{rep * 80}}, 70%, 50%)` }}
            }});
        }}

        Plotly.newPlot('storage-chart', storageData, {{
            title: 'Store Size by Rep (GB)',
            xaxis: {{ title: 'Configuration' }},
            yaxis: {{ title: 'Store Size (GB)' }},
            barmode: 'group'
        }});

        // Memory usage
        const memoryData = [
            {{
                x: configs,
                y: {system_data.get('memory_segments', [])},
                type: 'bar',
                name: 'Segments',
                marker: {{ color: '#34495e' }}
            }},
            {{
                x: configs,
                y: {system_data.get('memory_terms', [])},
                type: 'bar',
                name: 'Terms',
                marker: {{ color: '#2c3e50' }}
            }},
            {{
                x: configs,
                y: {system_data.get('memory_doc_values', [])},
                type: 'bar',
                name: 'Doc Values',
                marker: {{ color: '#7f8c8d' }}
            }}
        ];

        Plotly.newPlot('memory-chart', memoryData, {{
            title: 'Memory Usage (MB)',
            xaxis: {{ title: 'Configuration' }},
            yaxis: {{ title: 'Memory (MB)' }},
            barmode: 'group'
        }});

        // Counts
        const countsData = [
            {{
                x: configs,
                y: {system_data.get('merge_count', [])},
                type: 'bar',
                name: 'Merge Count',
                marker: {{ color: '#9b59b6' }}
            }},
            {{
                x: configs,
                y: {system_data.get('refresh_count', [])},
                type: 'bar',
                name: 'Refresh Count',
                marker: {{ color: '#f39c12' }}
            }},
            {{
                x: configs,
                y: {system_data.get('flush_count', [])},
                type: 'bar',
                name: 'Flush Count',
                marker: {{ color: '#e67e22' }}
            }},
            {{
                x: configs,
                y: {system_data.get('segment_count', [])},
                type: 'bar',
                name: 'Segment Count',
                marker: {{ color: '#1abc9c' }},
                yaxis: 'y2'
            }}
        ];

        Plotly.newPlot('counts-chart', countsData, {{
            title: 'Operation & Segment Counts',
            xaxis: {{ title: 'Configuration' }},
            yaxis: {{ title: 'Operation Count', side: 'left' }},
            yaxis2: {{ title: 'Segment Count', side: 'right', overlaying: 'y' }},
            barmode: 'group'
        }});

        {task_scripts}
    </script>
</body>
</html>'''
    
    return html_content

if __name__ == "__main__":
    data_dir = sys.argv[1] if len(sys.argv) > 1 else os.environ.get('OS_DATA')
    if not data_dir:
        print("Usage: python generate_combined_dashboard.py <data_directory>")
        sys.exit(1)
    
    html_content = generate_html(data_dir)
    
    output_dir = os.path.join(os.path.dirname(__file__), 'output')
    os.makedirs(output_dir, exist_ok=True)
    
    output_file = os.path.join(output_dir, 'combined.html')
    with open(output_file, 'w') as f:
        f.write(html_content)
    
    print(f"Combined dashboard generated: {output_file}")
