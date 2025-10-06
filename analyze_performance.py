#!/usr/bin/env python3
import json
import os
import glob
import pandas as pd
import numpy as np
import re
import matplotlib.pyplot as plt
import seaborn as sns
from pathlib import Path

def parse_filename(filename):
    """Extract clients, nodes, shards, repetition from filename"""
    match = re.match(r'(\d+)_(\d+)-(\d+)_(\d+)', filename)
    if match:
        return int(match.group(1)), int(match.group(2)), int(match.group(3)), int(match.group(4))
    return None, None, None, None

def load_summary_data(data_dir):
    """Load all summary JSON files"""
    summary_files = glob.glob(os.path.join(data_dir, "*_summary.json"))
    data = []
    
    for file_path in summary_files:
        filename = os.path.basename(file_path).replace('_summary.json', '')
        clients, nodes, shards, rep = parse_filename(filename)
        
        if clients is None:
            continue
            
        try:
            with open(file_path, 'r') as f:
                summary = json.load(f)
                
            record = {
                'clients': clients,
                'nodes': nodes,
                'shards': shards,
                'repetition': rep,
                'config': f"{clients}_{nodes}-{shards}",
                'throughput_mean': summary['throughput']['mean'],
                'throughput_min': summary['throughput']['min'],
                'throughput_max': summary['throughput']['max'],
                'latency_p50': summary['latency']['50_0'],
                'latency_p90': summary['latency']['90_0'],
                'latency_p99': summary['latency']['99_0'],
                'latency_mean': summary['latency']['mean'],
                'error_rate': summary['error_rate']
            }
            data.append(record)
        except Exception as e:
            print(f"Error loading {file_path}: {e}")
    
    return pd.DataFrame(data)

def analyze_repetitions(df):
    """Analyze individual repetitions for outliers"""
    print("=== REPETITION-LEVEL ANALYSIS ===\n")
    
    configs = df.groupby(['clients', 'nodes', 'shards'])
    outliers = []
    
    for (clients, nodes, shards), group in configs:
        if len(group) < 2:
            print(f"Configuration {clients}_{nodes}-{shards}: Only 1 repetition - cannot detect outliers")
            continue
            
        print(f"Configuration: {clients} clients, {nodes} nodes, {shards} shards")
        print(f"Repetitions: {len(group)}")
        
        # Calculate statistics
        throughput_mean = group['throughput_mean'].mean()
        throughput_std = group['throughput_mean'].std()
        latency_p99_mean = group['latency_p99'].mean()
        latency_p99_std = group['latency_p99'].std()
        
        print(f"Throughput: {throughput_mean:.0f} ± {throughput_std:.0f} docs/s (CV: {throughput_std/throughput_mean*100:.1f}%)")
        print(f"P99 Latency: {latency_p99_mean:.1f} ± {latency_p99_std:.1f} ms (CV: {latency_p99_std/latency_p99_mean*100:.1f}%)")
        
        # Show individual repetitions
        for _, row in group.iterrows():
            throughput_z = abs(row['throughput_mean'] - throughput_mean) / throughput_std if throughput_std > 0 else 0
            latency_z = abs(row['latency_p99'] - latency_p99_mean) / latency_p99_std if latency_p99_std > 0 else 0
            
            status = ""
            if throughput_z > 2 or latency_z > 2:
                outliers.append({
                    'config': f"{clients}_{nodes}-{shards}",
                    'repetition': row['repetition'],
                    'throughput_z': throughput_z,
                    'latency_z': latency_z,
                    'reason': 'throughput' if throughput_z > 2 else 'latency'
                })
                status = " [OUTLIER]"
            
            print(f"  Rep {row['repetition']}: {row['throughput_mean']:.0f} docs/s, {row['latency_p99']:.1f}ms P99{status}")
        
        print()
    
    return outliers

def analyze_aggregates(df):
    """Analyze aggregate performance across configurations"""
    print("=== AGGREGATE CONFIGURATION ANALYSIS ===\n")
    
    # Group by configuration and calculate statistics
    agg_stats = df.groupby(['clients', 'nodes', 'shards']).agg({
        'throughput_mean': ['mean', 'std', 'count'],
        'latency_p50': ['mean', 'std'],
        'latency_p90': ['mean', 'std'],
        'latency_p99': ['mean', 'std'],
        'error_rate': 'max'
    }).round(2)
    
    # Flatten column names
    agg_stats.columns = ['_'.join(col).strip() for col in agg_stats.columns]
    agg_stats = agg_stats.reset_index()
    
    # Sort by throughput
    agg_stats = agg_stats.sort_values('throughput_mean_mean', ascending=False)
    
    print("Performance Summary (sorted by throughput):")
    print("Config\t\tThroughput (docs/s)\tP50\tP90\tP99\tReps\tErrors")
    print("-" * 80)
    
    for _, row in agg_stats.iterrows():
        config = f"{row['clients']}_{row['nodes']}-{row['shards']}"
        throughput = f"{row['throughput_mean_mean']:.0f}±{row['throughput_mean_std']:.0f}"
        p50 = f"{row['latency_p50_mean']:.0f}"
        p90 = f"{row['latency_p90_mean']:.0f}"
        p99 = f"{row['latency_p99_mean']:.0f}"
        reps = f"{row['throughput_mean_count']:.0f}"
        errors = f"{row['error_rate_max']:.3f}"
        
        print(f"{config:<12}\t{throughput:<15}\t{p50}\t{p90}\t{p99}\t{reps}\t{errors}")
    
    return agg_stats

def generate_recommendations(df, agg_stats):
    """Generate scaling recommendations"""
    print("\n=== SCALING RECOMMENDATIONS ===\n")
    
    if len(agg_stats) == 0:
        print("No data available for recommendations")
        return
    
    # Find best configurations for different priorities
    best_throughput = agg_stats.loc[agg_stats['throughput_mean_mean'].idxmax()]
    best_latency_p99 = agg_stats.loc[agg_stats['latency_p99_mean'].idxmin()]
    
    # Calculate efficiency (throughput per node)
    agg_stats['efficiency'] = agg_stats['throughput_mean_mean'] / agg_stats['nodes']
    best_efficiency = agg_stats.loc[agg_stats['efficiency'].idxmax()]
    
    print("1. Maximum Throughput:")
    print(f"   Configuration: {best_throughput['clients']} clients, {best_throughput['nodes']} nodes, {best_throughput['shards']} shards")
    print(f"   Performance: {best_throughput['throughput_mean_mean']:.0f} docs/s, {best_throughput['latency_p99_mean']:.0f}ms P99")
    
    print("\n2. Lowest P99 Latency:")
    print(f"   Configuration: {best_latency_p99['clients']} clients, {best_latency_p99['nodes']} nodes, {best_latency_p99['shards']} shards")
    print(f"   Performance: {best_latency_p99['throughput_mean_mean']:.0f} docs/s, {best_latency_p99['latency_p99_mean']:.0f}ms P99")
    
    print("\n3. Best Efficiency (throughput per node):")
    print(f"   Configuration: {best_efficiency['clients']} clients, {best_efficiency['nodes']} nodes, {best_efficiency['shards']} shards")
    print(f"   Performance: {best_efficiency['throughput_mean_mean']:.0f} docs/s, {best_efficiency['efficiency']:.0f} docs/s/node")
    
    # Scaling analysis
    print("\n4. Scaling Patterns:")
    if len(agg_stats) > 1:
        # Group by different dimensions
        if len(agg_stats['nodes'].unique()) > 1:
            node_scaling = agg_stats.groupby('nodes').agg({
                'throughput_mean_mean': 'mean',
                'latency_p99_mean': 'mean',
                'efficiency': 'mean'
            }).round(0)
            
            print("   Node Scaling:")
            print("   Nodes -> Throughput, P99 Latency, Efficiency")
            for nodes, row in node_scaling.iterrows():
                print(f"   {nodes:2d} -> {row['throughput_mean_mean']:6.0f} docs/s, {row['latency_p99_mean']:4.0f}ms, {row['efficiency']:4.0f} docs/s/node")
        
        if len(agg_stats['clients'].unique()) > 1:
            client_scaling = agg_stats.groupby('clients').agg({
                'throughput_mean_mean': 'mean',
                'latency_p99_mean': 'mean'
            }).round(0)
            
            print("   Client Scaling:")
            print("   Clients -> Throughput, P99 Latency")
            for clients, row in client_scaling.iterrows():
                print(f"   {clients:3d} -> {row['throughput_mean_mean']:6.0f} docs/s, {row['latency_p99_mean']:4.0f}ms")
    else:
        print("   Only one configuration available - cannot analyze scaling patterns")

def create_visualizations(df, output_dir):
    """Create performance visualization charts"""
    if df.empty:
        print("No data available for visualizations")
        return
    
    plt.style.use('default')
    fig, axes = plt.subplots(2, 2, figsize=(15, 10))
    
    # 1. Throughput vs Latency scatter
    ax1 = axes[0, 0]
    for config in df['config'].unique():
        config_data = df[df['config'] == config]
        ax1.scatter(config_data['latency_p99'], config_data['throughput_mean'], 
                   label=config, alpha=0.7, s=100)
    
    ax1.set_xlabel('P99 Latency (ms)')
    ax1.set_ylabel('Throughput (docs/s)')
    ax1.set_title('Throughput vs P99 Latency')
    ax1.legend()
    ax1.grid(True, alpha=0.3)
    
    # 2. Throughput distribution by configuration
    ax2 = axes[0, 1]
    configs = df['config'].unique()
    throughputs = [df[df['config'] == config]['throughput_mean'].values for config in configs]
    ax2.boxplot(throughputs, labels=configs)
    ax2.set_ylabel('Throughput (docs/s)')
    ax2.set_title('Throughput Distribution by Configuration')
    ax2.tick_params(axis='x', rotation=45)
    
    # 3. Latency percentiles comparison
    ax3 = axes[1, 0]
    agg_data = df.groupby('config')[['latency_p50', 'latency_p90', 'latency_p99']].mean()
    x = range(len(agg_data))
    width = 0.25
    
    ax3.bar([i - width for i in x], agg_data['latency_p50'], width, label='P50', alpha=0.8)
    ax3.bar(x, agg_data['latency_p90'], width, label='P90', alpha=0.8)
    ax3.bar([i + width for i in x], agg_data['latency_p99'], width, label='P99', alpha=0.8)
    
    ax3.set_xlabel('Configuration')
    ax3.set_ylabel('Latency (ms)')
    ax3.set_title('Latency Percentiles by Configuration')
    ax3.set_xticks(x)
    ax3.set_xticklabels(agg_data.index, rotation=45)
    ax3.legend()
    
    # 4. Repetition variance
    ax4 = axes[1, 1]
    variance_data = df.groupby('config')['throughput_mean'].agg(['mean', 'std']).reset_index()
    variance_data['cv'] = variance_data['std'] / variance_data['mean'] * 100
    
    bars = ax4.bar(variance_data['config'], variance_data['cv'])
    ax4.set_ylabel('Coefficient of Variation (%)')
    ax4.set_title('Throughput Variance Across Repetitions')
    ax4.tick_params(axis='x', rotation=45)
    
    # Add value labels on bars
    for bar, cv in zip(bars, variance_data['cv']):
        height = bar.get_height()
        ax4.text(bar.get_x() + bar.get_width()/2., height + 0.1,
                f'{cv:.1f}%', ha='center', va='bottom')
    
    plt.tight_layout()
    
    # Save plot
    os.makedirs(output_dir, exist_ok=True)
    plt.savefig(os.path.join(output_dir, 'performance_analysis.png'), dpi=300, bbox_inches='tight')
    print(f"\nVisualization saved to: {output_dir}/performance_analysis.png")
    
    plt.close()

def main():
    data_dir = "/home/geremy_cohen_arm_com/axion_opensearch/results/optimization/20251006_193245/c4a-64/4k/nyc_taxis"
    output_dir = "/home/geremy_cohen_arm_com/axion_opensearch/analysis_output"
    
    if not os.path.exists(data_dir):
        print(f"Data directory not found: {data_dir}")
        return
    
    print(f"Analyzing performance data from: {data_dir}\n")
    
    # Load data
    df = load_summary_data(data_dir)
    
    if df.empty:
        print("No summary data found!")
        return
    
    print(f"Loaded {len(df)} benchmark results")
    config_counts = df.groupby(['clients', 'nodes', 'shards']).size()
    print("Configurations found:")
    for (clients, nodes, shards), count in config_counts.items():
        print(f"  {clients} clients, {nodes} nodes, {shards} shards: {count} repetitions")
    print()
    
    # Perform analyses
    outliers = analyze_repetitions(df)
    agg_stats = analyze_aggregates(df)
    generate_recommendations(df, agg_stats)
    
    # Create visualizations
    create_visualizations(df, output_dir)
    
    # Data quality summary
    print(f"\n=== DATA QUALITY SUMMARY ===")
    print(f"Total runs: {len(df)}")
    print(f"Configurations: {len(df['config'].unique())}")
    print(f"Outliers detected: {len(outliers)}")
    print(f"Error rate range: {df['error_rate'].min():.3f} - {df['error_rate'].max():.3f}")
    
    if outliers:
        print("\nOutlier details:")
        for outlier in outliers:
            print(f"  {outlier['config']} rep {outlier['repetition']}: {outlier['reason']} outlier (z-score: {outlier[outlier['reason']+'_z']:.2f})")
    
    # Save detailed results
    os.makedirs(output_dir, exist_ok=True)
    df.to_csv(os.path.join(output_dir, 'raw_results.csv'), index=False)
    agg_stats.to_csv(os.path.join(output_dir, 'aggregate_stats.csv'), index=False)
    
    print(f"\nDetailed results saved to: {output_dir}/")
    print("Files: raw_results.csv, aggregate_stats.csv, performance_analysis.png")

if __name__ == "__main__":
    main()
