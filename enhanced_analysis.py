#!/usr/bin/env python3
import json
import os
import glob
import pandas as pd
import numpy as np
import re
from pathlib import Path

def parse_metrics_file(file_path):
    """Parse metrics file to extract cluster health data"""
    try:
        with open(file_path, 'r') as f:
            content = f.read()
        
        # Extract JSON objects from the metrics file
        metrics = []
        for line in content.strip().split('\n'):
            if line.strip():
                try:
                    metric = json.loads(line)
                    metrics.append(metric)
                except json.JSONDecodeError:
                    continue
        
        return metrics
    except Exception as e:
        print(f"Error parsing {file_path}: {e}")
        return []

def analyze_cluster_health(data_dir):
    """Analyze cluster health metrics during benchmarks"""
    print("=== CLUSTER HEALTH ANALYSIS ===\n")
    
    metrics_files = glob.glob(os.path.join(data_dir, "metrics_*"))
    
    for metrics_file in sorted(metrics_files):
        filename = os.path.basename(metrics_file)
        
        # Extract configuration from filename
        match = re.match(r'metrics_(\d+)_(\d+)-(\d+)_(\d+)_(\d+)', filename)
        if not match:
            continue
            
        clients, nodes, shards, rep, sample = match.groups()
        config = f"{clients}_{nodes}-{shards}_rep{rep}"
        
        metrics = parse_metrics_file(metrics_file)
        if not metrics:
            continue
            
        print(f"Configuration: {config}, Sample: {sample}")
        
        # Analyze key metrics
        cpu_usage = []
        memory_usage = []
        disk_usage = []
        
        for metric in metrics:
            if 'cpu_percent' in metric:
                cpu_usage.append(metric['cpu_percent'])
            if 'memory_percent' in metric:
                memory_usage.append(metric['memory_percent'])
            if 'disk_usage_percent' in metric:
                disk_usage.append(metric['disk_usage_percent'])
        
        if cpu_usage:
            print(f"  CPU Usage: {np.mean(cpu_usage):.1f}% avg, {np.max(cpu_usage):.1f}% max")
        if memory_usage:
            print(f"  Memory Usage: {np.mean(memory_usage):.1f}% avg, {np.max(memory_usage):.1f}% max")
        if disk_usage:
            print(f"  Disk Usage: {np.mean(disk_usage):.1f}% avg, {np.max(disk_usage):.1f}% max")
        
        print()

def analyze_performance_variance(data_dir):
    """Detailed analysis of performance variance between repetitions"""
    print("=== PERFORMANCE VARIANCE ANALYSIS ===\n")
    
    summary_files = glob.glob(os.path.join(data_dir, "*_summary.json"))
    
    # Group by configuration
    configs = {}
    for file_path in summary_files:
        filename = os.path.basename(file_path).replace('_summary.json', '')
        match = re.match(r'(\d+)_(\d+)-(\d+)_(\d+)', filename)
        if not match:
            continue
            
        clients, nodes, shards, rep = match.groups()
        config_key = f"{clients}_{nodes}-{shards}"
        
        if config_key not in configs:
            configs[config_key] = []
            
        try:
            with open(file_path, 'r') as f:
                summary = json.load(f)
            configs[config_key].append({
                'rep': int(rep),
                'throughput': summary['throughput']['mean'],
                'latency_p50': summary['latency']['50_0'],
                'latency_p90': summary['latency']['90_0'],
                'latency_p99': summary['latency']['99_0']
            })
        except Exception as e:
            print(f"Error loading {file_path}: {e}")
    
    for config, reps in configs.items():
        if len(reps) < 2:
            continue
            
        print(f"Configuration: {config}")
        
        # Calculate variance metrics
        throughputs = [r['throughput'] for r in reps]
        p99_latencies = [r['latency_p99'] for r in reps]
        
        throughput_cv = np.std(throughputs) / np.mean(throughputs) * 100
        latency_cv = np.std(p99_latencies) / np.mean(p99_latencies) * 100
        
        print(f"  Throughput variance: {throughput_cv:.2f}% CV")
        print(f"  P99 latency variance: {latency_cv:.2f}% CV")
        
        # Performance difference between repetitions
        if len(reps) == 2:
            throughput_diff = abs(reps[1]['throughput'] - reps[0]['throughput'])
            throughput_diff_pct = throughput_diff / np.mean(throughputs) * 100
            
            latency_diff = abs(reps[1]['latency_p99'] - reps[0]['latency_p99'])
            latency_diff_pct = latency_diff / np.mean(p99_latencies) * 100
            
            print(f"  Rep-to-rep difference: {throughput_diff:.0f} docs/s ({throughput_diff_pct:.1f}%)")
            print(f"  Rep-to-rep latency diff: {latency_diff:.1f}ms ({latency_diff_pct:.1f}%)")
        
        print()

def generate_scaling_insights(data_dir):
    """Generate insights for scaling based on available data"""
    print("=== SCALING INSIGHTS ===\n")
    
    # Load performance data
    summary_files = glob.glob(os.path.join(data_dir, "*_summary.json"))
    
    if len(summary_files) < 2:
        print("Insufficient data for scaling analysis (need multiple configurations)")
        print("\nRecommendations for comprehensive analysis:")
        print("1. Test multiple client loads: 60, 70, 80, 90, 100")
        print("2. Test multiple node counts: 16, 20, 24, 28, 32")
        print("3. Run 3-4 repetitions per configuration for statistical significance")
        print("4. Monitor cluster health metrics during each run")
        return
    
    # If we had multiple configurations, we would analyze:
    print("Current dataset limitations:")
    print("- Only one configuration tested (70 clients, 16 nodes, 16 shards)")
    print("- Need multiple client loads to identify saturation point")
    print("- Need multiple node counts to analyze horizontal scaling")
    
    print("\nBased on current data (70 clients, 16 nodes):")
    
    # Load the available data
    with open(summary_files[0], 'r') as f:
        summary1 = json.load(f)
    with open(summary_files[1], 'r') as f:
        summary2 = json.load(f)
    
    avg_throughput = (summary1['throughput']['mean'] + summary2['throughput']['mean']) / 2
    avg_p99 = (summary1['latency']['99_0'] + summary2['latency']['99_0']) / 2
    
    print(f"- Average throughput: {avg_throughput:.0f} docs/s")
    print(f"- Average P99 latency: {avg_p99:.0f}ms")
    print(f"- Throughput per node: {avg_throughput/16:.0f} docs/s/node")
    
    # Provide scaling recommendations
    print("\nScaling recommendations:")
    print("1. Test higher client loads (80, 90, 100) to find saturation point")
    print("2. Test fewer nodes (8, 12) to see if efficiency improves")
    print("3. Test more nodes (20, 24) to see if throughput scales linearly")
    print("4. Monitor CPU/memory utilization to identify bottlenecks")

def main():
    data_dir = "/home/geremy_cohen_arm_com/axion_opensearch/results/optimization/20251006_193245/c4a-64/4k/nyc_taxis"
    
    if not os.path.exists(data_dir):
        print(f"Data directory not found: {data_dir}")
        return
    
    print(f"Enhanced analysis of: {data_dir}\n")
    
    # Perform enhanced analyses
    analyze_cluster_health(data_dir)
    analyze_performance_variance(data_dir)
    generate_scaling_insights(data_dir)
    
    print("=== SUMMARY ===")
    print("Current dataset contains limited configurations for comprehensive scaling analysis.")
    print("For optimal performance tuning, collect data across multiple client loads and node counts.")

if __name__ == "__main__":
    main()
