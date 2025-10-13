#!/usr/bin/env python3
"""
Script to update UI experiments with real data from performance analysis
Usage: OS_DATA=/path/to/data python update_ui_experiments.py
"""

import os
import sys
import json
import glob
import re
from pathlib import Path

def load_performance_data(data_dir):
    """Load performance data from summary files"""
    if not os.path.exists(data_dir):
        print(f"Error: Data directory not found: {data_dir}")
        sys.exit(1)
    
    data = []
    summary_files = glob.glob(f"{data_dir}/**/*_summary.json", recursive=True)
    
    if not summary_files:
        print(f"Error: No summary files found in {data_dir}")
        sys.exit(1)
    
    print(f"Found {len(summary_files)} summary files")
    
    for file_path in summary_files:
        try:
            with open(file_path, 'r') as f:
                summary = json.load(f)
            
            # Extract cluster info from path
            path_parts = Path(file_path).parts
            instance_type = None
            page_size = None
            workload = None
            
            for i, part in enumerate(path_parts):
                if part.startswith('c4'):
                    instance_type = part
                    if i + 1 < len(path_parts):
                        page_size = path_parts[i + 1]
                    if i + 2 < len(path_parts):
                        workload = path_parts[i + 2]
                    break
            
            if not all([instance_type, page_size, workload]):
                continue
                
            cluster_name = f"{instance_type} {page_size} - {workload}"
            # Clean cluster name for UI display
            clean_cluster_name = cluster_name.replace(" - nyc_taxis", "").replace(" nyc_taxis", "")
            
            # Extract performance metrics
            throughput = summary.get('throughput', {}).get('mean', 0)
            latency_p99 = summary.get('latency', {}).get('99_0', 0)
            latency_p90 = summary.get('latency', {}).get('90_0', 0)
            latency_p50 = summary.get('latency', {}).get('50_0', 0)
            error_rate = summary.get('error_rate', 0)
            
            # Extract configuration from filename
            filename = Path(file_path).stem
            config_match = re.search(r'(\d+)_(\d+)-(\d+)', filename)
            if config_match:
                clients, nodes, shards = config_match.groups()
                config = f"{clients}_{nodes}-{shards}"
            else:
                config = "unknown"
            
            # Extract repetition number
            rep_match = re.search(r'rep(\d+)', filename)
            rep = int(rep_match.group(1)) if rep_match else 1
            
            data.append({
                'cluster': clean_cluster_name,
                'config': config,
                'rep': rep,
                'throughput': int(throughput),
                'latency': int(latency_p99),
                'latency_p90': int(latency_p90),
                'latency_p50': int(latency_p50),
                'efficiency': int(throughput / (latency_p99 / 1000)) if latency_p99 > 0 else 0,
                'error_rate': error_rate,
                'clients': int(clients) if config_match else 60,
                'nodes': int(nodes) if config_match else 16,
                'shards': int(shards) if config_match else 16
            })
            
        except Exception as e:
            print(f"Error processing {file_path}: {e}")
            continue
    
    return data

def update_ui_experiment(experiment_file, data):
    """Update a UI experiment file with real data"""
    if not os.path.exists(experiment_file):
        print(f"Warning: {experiment_file} not found")
        return
    
    with open(experiment_file, 'r') as f:
        content = f.read()
    
    # Transform data based on UI experiment type
    if 'experiment_2' in experiment_file:
        # UI 2 needs grouped data by config with rep arrays
        transformed_data = transform_for_ui2(data)
        js_data = "const performanceData = " + json.dumps(transformed_data, indent=12) + ";"
    elif 'experiment_3' in experiment_file:
        # UI 3 needs nested structure by cluster and config
        transformed_data = transform_for_ui3(data)
        js_data = "const repData = " + json.dumps(transformed_data, indent=12) + ";"
    else:
        # UI 1, 4, 5 use flat array
        js_data = "const performanceData = " + json.dumps(data, indent=12) + ";"
    
    # Find and replace the data section more precisely
    if 'experiment_2' in experiment_file:
        # For UI 2, replace the entire performanceData array
        pattern = r'const performanceData = \[[\s\S]*?\];'
    elif 'experiment_3' in experiment_file:
        # For UI 3, replace repData
        pattern = r'const repData = \{[\s\S]*?\};'
    else:
        # For UI 1, 4, 5, replace performanceData array
        pattern = r'const performanceData = \[[\s\S]*?\];'
    
    if re.search(pattern, content):
        content = re.sub(pattern, js_data, content)
        updated = True
    else:
        print(f"Warning: Could not find data section in {experiment_file}")
        return
    
    # Write updated content
    with open(experiment_file, 'w') as f:
        f.write(content)
    
    print(f"Updated {experiment_file}")

def transform_for_ui2(data):
    """Transform data for UI experiment 2 (cluster comparison)"""
    # Group by cluster and config
    grouped = {}
    for item in data:
        key = f"{item['cluster']}_{item['config']}"
        if key not in grouped:
            grouped[key] = {
                'cluster': item['cluster'],
                'config': item['config'],
                'clients': item['clients'],
                'nodes': item['nodes'],
                'shards': item['shards'],
                'throughput': [],
                'latency': [],
                'latency_p90': [],
                'latency_p50': []
            }
        
        # Append all rep data (don't assume specific rep numbers)
        grouped[key]['throughput'].append(item['throughput'])
        grouped[key]['latency'].append(item['latency'])
        grouped[key]['latency_p90'].append(item['latency_p90'])
        grouped[key]['latency_p50'].append(item['latency_p50'])
    
    # Ensure we have 4 reps, pad with zeros if needed
    result = []
    for item in grouped.values():
        while len(item['throughput']) < 4:
            item['throughput'].append(0)
        while len(item['latency']) < 4:
            item['latency'].append(0)
        while len(item['latency_p90']) < 4:
            item['latency_p90'].append(0)
        while len(item['latency_p50']) < 4:
            item['latency_p50'].append(0)
        result.append(item)
    
    return result

def transform_for_ui3(data):
    """Transform data for UI experiment 3 (rep level analysis)"""
    # Group by cluster, then by config
    result = {}
    for item in data:
        cluster = item['cluster']
        config = item['config']
        
        if cluster not in result:
            result[cluster] = {}
        
        if config not in result[cluster]:
            result[cluster][config] = []
        
        result[cluster][config].append({
            'rep': item['rep'],
            'throughput': item['throughput'],
            'latency': item['latency'],
            'efficiency': item['efficiency'],
            'cpu': 70.0,  # Default values since not in summary
            'queue': 0
        })
    
    return result

def main():
    data_dir = os.environ.get('OS_DATA')
    if not data_dir:
        print("Error: OS_DATA environment variable not set")
        print("Usage: OS_DATA=/path/to/data python update_ui_experiments.py")
        sys.exit(1)
    
    print(f"Loading data from: {data_dir}")
    data = load_performance_data(data_dir)
    
    if not data:
        print("Error: No performance data loaded")
        sys.exit(1)
    
    print(f"Loaded {len(data)} data points from {len(set(d['cluster'] for d in data))} clusters")
    
    # Update all UI experiments
    ui_files = [
        'ui_experiment_1_efficiency_curve.html',
        'ui_experiment_2_cluster_comparison.html',
        'ui_experiment_3_rep_level_analysis.html',
        'ui_experiment_4_performance_bands.html',
        'ui_experiment_5_optimal_finder.html'
    ]
    
    for ui_file in ui_files:
        update_ui_experiment(ui_file, data)
    
    print(f"\nUpdated {len(ui_files)} UI experiments with real data")
    print("You can now refresh the HTML files in your browser to see the updated data")

if __name__ == "__main__":
    main()
