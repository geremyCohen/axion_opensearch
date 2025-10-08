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
import plotly.graph_objects as go
import plotly.express as px
from plotly.subplots import make_subplots
import plotly.offline as pyo
from scipy import stats

def parse_filename(filename):
    """Extract clients, nodes, shards, repetition from filename"""
    match = re.match(r'(\d+)_(\d+)-(\d+)_(\d+)', filename)
    if match:
        return int(match.group(1)), int(match.group(2)), int(match.group(3)), int(match.group(4))
    return None, None, None, None

def parse_cpu_metrics(data_dir, clients, nodes, shards, rep):
    """Parse CPU metrics from metrics files for a specific repetition"""
    pattern = f"metrics_{clients}_{nodes}-{shards}_{rep}_*"
    metrics_files = glob.glob(os.path.join(data_dir, pattern))
    
    cpu_data = []
    for file_path in metrics_files:
        try:
            with open(file_path, 'r') as f:
                lines = f.readlines()
                
            for line in lines[1:]:  # Skip timestamp header
                if line.strip() and line.startswith('{'):
                    data = json.loads(line)
                    if 'nodes' in data:
                        for node_id, node_info in data['nodes'].items():
                            if 'os' in node_info and 'cpu' in node_info['os']:
                                cpu_data.append({
                                    'cpu_percent': node_info['os']['cpu']['percent'],
                                    'load_1m': node_info['os']['cpu']['load_average']['1m'],
                                    'process_cpu': node_info['process']['cpu']['percent']
                                })
        except Exception as e:
            continue
    
    if cpu_data:
        cpu_df = pd.DataFrame(cpu_data)
        return {
            'cpu_avg': cpu_df['cpu_percent'].mean(),
            'cpu_peak': cpu_df['cpu_percent'].max(),
            'cpu_p95': cpu_df['cpu_percent'].quantile(0.95),
            'load_avg_1m': cpu_df['load_1m'].mean(),
            'process_cpu_avg': cpu_df['process_cpu'].mean()
        }
    
    return {
        'cpu_avg': 0, 'cpu_peak': 0, 'cpu_p95': 0, 
        'load_avg_1m': 0, 'process_cpu_avg': 0
    }

def parse_queue_metrics(data_dir, clients, nodes, shards, rep):
    """Parse thread pool queue metrics from metrics files for a specific repetition"""
    pattern = f"metrics_{clients}_{nodes}-{shards}_{rep}_*"
    metrics_files = glob.glob(os.path.join(data_dir, pattern))
    
    queue_data = []
    for file_path in metrics_files:
        try:
            with open(file_path, 'r') as f:
                lines = f.readlines()
                
            for line in lines[1:]:  # Skip timestamp header
                if line.strip() and line.startswith('{'):
                    data = json.loads(line)
                    if 'nodes' in data:
                        for node_id, node_info in data['nodes'].items():
                            if 'thread_pool' in node_info:
                                # Extract key thread pool metrics
                                thread_pools = node_info['thread_pool']
                                
                                # Focus on important thread pools for indexing/search
                                important_pools = ['write', 'search', 'generic', 'refresh', 'flush']
                                
                                for pool_name in important_pools:
                                    if pool_name in thread_pools:
                                        pool = thread_pools[pool_name]
                                        queue_data.append({
                                            'pool': pool_name,
                                            'queue': pool.get('queue', 0),
                                            'active': pool.get('active', 0),
                                            'rejected': pool.get('rejected', 0),
                                            'threads': pool.get('threads', 0),
                                            'largest': pool.get('largest', 0)
                                        })
        except Exception as e:
            continue
    
    if queue_data:
        queue_df = pd.DataFrame(queue_data)
        
        # Calculate aggregate metrics across all pools and nodes
        total_queue = queue_df['queue'].sum()
        total_active = queue_df['active'].sum()
        total_rejected = queue_df['rejected'].sum()
        max_queue = queue_df['queue'].max()
        max_rejected = queue_df['rejected'].max()
        
        # Pool-specific metrics
        write_queue = queue_df[queue_df['pool'] == 'write']['queue'].sum()
        search_queue = queue_df[queue_df['pool'] == 'search']['queue'].sum()
        
        return {
            'total_queue': total_queue,
            'total_active': total_active,
            'total_rejected': total_rejected,
            'max_queue': max_queue,
            'max_rejected': max_rejected,
            'write_queue': write_queue,
            'search_queue': search_queue
        }
    
    return {
        'total_queue': 0, 'total_active': 0, 'total_rejected': 0,
        'max_queue': 0, 'max_rejected': 0, 'write_queue': 0, 'search_queue': 0
    }

def load_summary_data(data_dir):
    """Load all summary JSON files and parse CPU metrics"""
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
            
            # Parse CPU metrics for this repetition
            cpu_metrics = parse_cpu_metrics(data_dir, clients, nodes, shards, rep)
            
            # Parse queue metrics for this repetition
            queue_metrics = parse_queue_metrics(data_dir, clients, nodes, shards, rep)
                
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
                'error_rate': summary['error_rate'],
                'cpu_avg': cpu_metrics['cpu_avg'],
                'cpu_peak': cpu_metrics['cpu_peak'],
                'cpu_p95': cpu_metrics['cpu_p95'],
                'load_avg_1m': cpu_metrics['load_avg_1m'],
                'process_cpu_avg': cpu_metrics['process_cpu_avg'],
                'total_queue': queue_metrics['total_queue'],
                'total_active': queue_metrics['total_active'],
                'total_rejected': queue_metrics['total_rejected'],
                'max_queue': queue_metrics['max_queue'],
                'max_rejected': queue_metrics['max_rejected'],
                'write_queue': queue_metrics['write_queue'],
                'search_queue': queue_metrics['search_queue']
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

def create_repetition_analysis(df):
    """Tab 1: Repetition Analysis - Validate data quality and identify outliers"""
    
    # Individual repetition metrics table with CPU and queue data
    rep_metrics = df[['config', 'repetition', 'throughput_mean', 'latency_p50', 'latency_p90', 'latency_p99', 
                     'error_rate', 'cpu_avg', 'cpu_peak', 'cpu_p95', 'load_avg_1m', 
                     'total_queue', 'total_rejected', 'max_queue', 'write_queue', 'search_queue']].copy()
    rep_metrics['duration'] = 3600  # Placeholder - would need actual duration from logs
    
    # Coefficient of variation analysis including CPU and queue metrics
    cv_analysis = df.groupby('config').agg({
        'throughput_mean': lambda x: x.std() / x.mean() * 100,
        'latency_p50': lambda x: x.std() / x.mean() * 100,
        'latency_p90': lambda x: x.std() / x.mean() * 100,
        'latency_p99': lambda x: x.std() / x.mean() * 100,
        'cpu_avg': lambda x: x.std() / x.mean() * 100 if x.mean() > 0 else 0,
        'cpu_peak': lambda x: x.std() / x.mean() * 100 if x.mean() > 0 else 0,
        'load_avg_1m': lambda x: x.std() / x.mean() * 100 if x.mean() > 0 else 0,
        'total_queue': lambda x: x.std() / x.mean() * 100 if x.mean() > 0 else 0,
        'total_rejected': lambda x: x.std() / x.mean() * 100 if x.mean() > 0 else 0,
        'max_queue': lambda x: x.std() / x.mean() * 100 if x.mean() > 0 else 0
    }).round(2)
    cv_analysis.columns = [f'{col}_cv' for col in cv_analysis.columns]
    
    # Outlier detection (>2σ from mean) including CPU and queue metrics
    outliers_df = []
    for config in df['config'].unique():
        config_data = df[df['config'] == config]
        if len(config_data) < 2:
            continue
            
        for metric in ['throughput_mean', 'latency_p99', 'cpu_avg', 'cpu_peak', 'total_queue', 'total_rejected', 'max_queue']:
            mean_val = config_data[metric].mean()
            std_val = config_data[metric].std()
            if std_val > 0:
                z_scores = np.abs((config_data[metric] - mean_val) / std_val)
                outlier_mask = z_scores > 2
                for idx, is_outlier in outlier_mask.items():
                    if is_outlier:
                        outliers_df.append({
                            'config': config,
                            'repetition': config_data.loc[idx, 'repetition'],
                            'metric': metric,
                            'z_score': z_scores[idx],
                            'value': config_data.loc[idx, metric]
                        })
    
    outliers_table = pd.DataFrame(outliers_df)
    
    # Box plots for metric distributions including CPU and queue metrics
    box_plots = {}
    for metric in ['throughput_mean', 'latency_p50', 'latency_p90', 'latency_p99', 'cpu_avg', 'cpu_peak', 'total_queue', 'max_queue', 'total_rejected']:
        fig = px.box(df, x='config', y=metric, title=f'{metric.replace("_", " ").title()} Distribution')
        box_plots[metric] = fig
    
    # Scatter plot: throughput vs CPU
    cpu_scatter_fig = px.scatter(df, x='cpu_avg', y='throughput_mean', color='config',
                               title='Throughput vs Average CPU by Repetition',
                               hover_data=['repetition', 'cpu_peak'])
    
    # Scatter plot: throughput vs queue depth
    queue_scatter_fig = px.scatter(df, x='total_queue', y='throughput_mean', color='config',
                                 title='Throughput vs Total Queue Depth by Repetition',
                                 hover_data=['repetition', 'max_queue', 'total_rejected'])
    
    # Scatter plot: throughput vs P90 latency (existing)
    scatter_fig = px.scatter(df, x='latency_p90', y='throughput_mean', color='config',
                           title='Throughput vs P90 Latency by Repetition',
                           hover_data=['repetition'])
    
    return {
        'rep_metrics': rep_metrics,
        'cv_analysis': cv_analysis,
        'outliers': outliers_table,
        'box_plots': box_plots,
        'scatter_plot': scatter_fig,
        'cpu_scatter_plot': cpu_scatter_fig,
        'queue_scatter_plot': queue_scatter_fig
    }

def create_run_level_analysis(df):
    """Tab 2: Run Level Analysis - Performance characteristics per configuration"""
    
    # Aggregated metrics per configuration
    agg_metrics = df.groupby('config').agg({
        'throughput_mean': ['mean', 'std', 'min', 'max'],
        'latency_p50': ['mean', 'std'],
        'latency_p90': ['mean', 'std'],
        'latency_p99': ['mean', 'std'],
        'error_rate': ['mean', 'max'],
        'cpu_avg': ['mean', 'max'],
        'cpu_peak': ['mean', 'max'],
        'load_avg_1m': ['mean', 'max'],
        'total_queue': ['mean', 'max'],
        'total_rejected': ['sum', 'max'],
        'max_queue': ['mean', 'max'],
        'write_queue': ['mean', 'max'],
        'search_queue': ['mean', 'max'],
        'nodes': 'first',
        'clients': 'first'
    }).round(2)
    
    # Flatten column names
    agg_metrics.columns = ['_'.join(col).strip() for col in agg_metrics.columns]
    agg_metrics = agg_metrics.reset_index()
    
    # Performance efficiency ratios
    agg_metrics['docs_per_node'] = agg_metrics['throughput_mean_mean'] / agg_metrics['nodes_first']
    agg_metrics['latency_per_gb'] = agg_metrics['latency_p99_mean'] / 10  # Assuming ~10GB indexed
    
    # Queue health indicators
    agg_metrics['queue_pressure'] = agg_metrics['total_queue_mean'] + agg_metrics['total_rejected_sum']
    agg_metrics['write_efficiency'] = agg_metrics['throughput_mean_mean'] / (agg_metrics['write_queue_mean'] + 1)  # +1 to avoid division by zero
    
    # Performance profile radar charts
    radar_charts = {}
    for config in agg_metrics['config']:
        config_data = agg_metrics[agg_metrics['config'] == config].iloc[0]
        
        # Normalize metrics for radar chart (0-100 scale)
        throughput_norm = min(100, config_data['throughput_mean_mean'] / 50000 * 100)
        latency_norm = max(0, 100 - config_data['latency_p99_mean'] / 1000 * 100)
        efficiency_norm = min(100, config_data['docs_per_node'] / 10000 * 100)
        cpu_norm = max(0, 100 - config_data['cpu_avg_mean'])  # Lower CPU usage = better
        queue_norm = max(0, 100 - config_data['queue_pressure'])  # Lower queue pressure = better
        
        categories = ['Throughput', 'Low Latency', 'Efficiency', 'CPU Available', 'Queue Health']
        values = [throughput_norm, latency_norm, efficiency_norm, cpu_norm, queue_norm]
        
        fig = go.Figure()
        fig.add_trace(go.Scatterpolar(
            r=values + [values[0]],  # Close the polygon
            theta=categories + [categories[0]],
            fill='toself',
            name=config
        ))
        fig.update_layout(
            polar=dict(radialaxis=dict(visible=True, range=[0, 100])),
            title=f'Performance Profile: {config}'
        )
        radar_charts[config] = fig
    
    # Resource utilization heatmap using actual metrics
    heatmap_data = agg_metrics[['config', 'cpu_avg_mean', 'cpu_peak_mean', 'load_avg_1m_mean', 'total_queue_mean']].set_index('config')
    heatmap_fig = px.imshow(heatmap_data.T, 
                           title='Resource Utilization Heatmap',
                           color_continuous_scale='RdYlBu_r',
                           aspect='auto')
    
    # Throughput vs resource correlation
    corr_fig = px.scatter(agg_metrics, x='cpu_avg_mean', y='throughput_mean_mean', 
                         size='nodes_first', color='config',
                         title='Throughput vs CPU Utilization')
    
    # Latency vs CPU Utilization
    latency_cpu_fig = px.scatter(agg_metrics, x='cpu_avg_mean', y='latency_p99_mean',
                                size='nodes_first', color='config',
                                title='Latency vs CPU Utilization')
    
    # Throughput vs Queue Pressure
    throughput_queue_fig = px.scatter(agg_metrics, x='queue_pressure', y='throughput_mean_mean',
                                     size='nodes_first', color='config',
                                     title='Throughput vs Queue Pressure')
    
    # Throughput vs Latency
    throughput_latency_fig = px.scatter(agg_metrics, x='latency_p90_mean', y='throughput_mean_mean',
                                       size='nodes_first', color='config',
                                       title='Throughput vs Latency')
    
    return {
        'agg_metrics': agg_metrics,
        'radar_charts': radar_charts,
        'heatmap': heatmap_fig,
        'correlation': corr_fig,
        'latency_cpu': latency_cpu_fig,
        'throughput_queue': throughput_queue_fig,
        'throughput_latency': throughput_latency_fig
    }

def create_config_comparison(df):
    """Tab 3: Config Level Comparison - Optimal configurations and scaling patterns"""
    
    # Configuration ranking
    config_summary = df.groupby(['config', 'clients', 'nodes', 'shards']).agg({
        'throughput_mean': 'mean',
        'latency_p50': 'mean',
        'latency_p90': 'mean',
        'latency_p99': 'mean',
        'error_rate': 'max'
    }).reset_index()
    
    config_summary['efficiency'] = config_summary['throughput_mean'] / config_summary['nodes']
    config_summary['throughput_rank'] = config_summary['throughput_mean'].rank(ascending=False)
    config_summary['latency_rank'] = config_summary['latency_p99'].rank(ascending=True)
    config_summary['efficiency_rank'] = config_summary['efficiency'].rank(ascending=False)
    
    # Scaling coefficients
    scaling_analysis = {}
    if len(config_summary['nodes'].unique()) > 1:
        # Node scaling
        node_groups = config_summary.groupby('nodes')['throughput_mean'].mean().reset_index()
        if len(node_groups) > 1:
            slope, intercept, r_value, p_value, std_err = stats.linregress(node_groups['nodes'], node_groups['throughput_mean'])
            scaling_analysis['node_scaling'] = {
                'slope': slope,
                'r_squared': r_value**2,
                'efficiency': 'Linear' if r_value**2 > 0.9 else 'Sub-linear'
            }
    
    if len(config_summary['clients'].unique()) > 1:
        # Client scaling
        client_groups = config_summary.groupby('clients')['throughput_mean'].mean().reset_index()
        if len(client_groups) > 1:
            slope, intercept, r_value, p_value, std_err = stats.linregress(client_groups['clients'], client_groups['throughput_mean'])
            scaling_analysis['client_scaling'] = {
                'slope': slope,
                'r_squared': r_value**2,
                'efficiency': 'Linear' if r_value**2 > 0.9 else 'Sub-linear'
            }
    
    # Cost-benefit matrix (placeholder costs)
    config_summary['cost_score'] = config_summary['nodes'] * 100 + config_summary['clients'] * 10
    config_summary['benefit_score'] = config_summary['throughput_mean'] / 1000
    config_summary['cost_benefit_ratio'] = config_summary['benefit_score'] / config_summary['cost_score']
    
    # Multi-dimensional scaling chart
    scaling_fig = px.scatter_3d(config_summary, x='clients', y='nodes', z='throughput_mean',
                               color='latency_p99', size='efficiency',
                               title='3D Performance Landscape',
                               hover_data=['config'])
    
    # Pareto frontier: throughput vs P90 latency
    pareto_fig = px.scatter(config_summary, x='latency_p90', y='throughput_mean',
                           color='nodes', size='clients',
                           title='Pareto Frontier: Throughput vs P90 Latency',
                           hover_data=['config'])
    
    # Scaling efficiency curves
    efficiency_fig = make_subplots(rows=1, cols=2, 
                                  subplot_titles=['Node Scaling', 'Client Scaling'])
    
    if len(config_summary['nodes'].unique()) > 1:
        node_eff = config_summary.groupby('nodes').agg({
            'throughput_mean': 'mean',
            'efficiency': 'mean'
        }).reset_index()
        
        efficiency_fig.add_trace(
            go.Scatter(x=node_eff['nodes'], y=node_eff['throughput_mean'],
                      mode='lines+markers', name='Actual Throughput'),
            row=1, col=1
        )
        
        # Linear scaling baseline
        linear_throughput = node_eff['throughput_mean'].iloc[0] * node_eff['nodes'] / node_eff['nodes'].iloc[0]
        efficiency_fig.add_trace(
            go.Scatter(x=node_eff['nodes'], y=linear_throughput,
                      mode='lines', name='Linear Scaling', line=dict(dash='dash')),
            row=1, col=1
        )
    
    if len(config_summary['clients'].unique()) > 1:
        client_eff = config_summary.groupby('clients')['throughput_mean'].mean().reset_index()
        
        efficiency_fig.add_trace(
            go.Scatter(x=client_eff['clients'], y=client_eff['throughput_mean'],
                      mode='lines+markers', name='Actual Throughput'),
            row=1, col=2
        )
    
    efficiency_fig.update_layout(title='Scaling Efficiency Analysis')
    
    return {
        'config_ranking': config_summary,
        'scaling_analysis': scaling_analysis,
        'cost_benefit': config_summary[['config', 'cost_score', 'benefit_score', 'cost_benefit_ratio']],
        'scaling_3d': scaling_fig,
        'pareto_frontier': pareto_fig,
        'efficiency_curves': efficiency_fig
    }

def generate_html_dashboard(rep_analysis, run_analysis, config_analysis, output_dir):
    """Generate comprehensive HTML dashboard with three tabs"""
    
    html_content = f"""
    <!DOCTYPE html>
    <html>
    <head>
        <title>OpenSearch Performance Analysis Dashboard</title>
        <script src="https://cdn.plot.ly/plotly-latest.min.js"></script>
        <style>
            body {{ font-family: Arial, sans-serif; margin: 20px; }}
            .tab {{ overflow: hidden; border: 1px solid #ccc; background-color: #f1f1f1; }}
            .tab button {{ background-color: inherit; float: left; border: none; outline: none; cursor: pointer; padding: 14px 16px; transition: 0.3s; }}
            .tab button:hover {{ background-color: #ddd; }}
            .tab button.active {{ background-color: #ccc; }}
            .tabcontent {{ display: none; padding: 12px; border: 1px solid #ccc; border-top: none; }}
            .tabcontent.active {{ display: block; }}
            table {{ border-collapse: collapse; width: 100%; margin: 10px 0; }}
            th, td {{ border: 1px solid #ddd; padding: 8px; text-align: left; }}
            th {{ background-color: #f2f2f2; }}
            .chart-container {{ margin: 20px 0; }}
            .metrics-grid {{ display: grid; grid-template-columns: 1fr 1fr; gap: 20px; margin: 20px 0; }}
        </style>
    </head>
    <body>
        <h1>OpenSearch Performance Analysis Dashboard</h1>
        
        <div class="tab">
            <button class="tablinks active" onclick="openTab(event, 'RepetitionAnalysis')">Repetition Analysis</button>
            <button class="tablinks" onclick="openTab(event, 'RunLevelAnalysis')">Run Level Analysis</button>
            <button class="tablinks" onclick="openTab(event, 'ConfigComparison')">Config Comparison</button>
        </div>
        
        <!-- Tab 1: Repetition Analysis -->
        <div id="RepetitionAnalysis" class="tabcontent active">
            <h2>Repetition Analysis - Data Quality Validation</h2>
            
            <h3>Individual Repetition Metrics</h3>
            <p>Shows <strong>raw performance data for each individual benchmark run</strong> within each configuration.</p>
            
            <p><strong>What it contains:</strong><br>
            • <strong>repetition</strong>: Run number (4, 3, 2, 1 in descending order)<br>
            • <strong>throughput_mean</strong>: Average documents indexed per second during that run<br>
            • <strong>latency_p50/p90/p99</strong>: 50th, 90th, and 99th percentile response times in milliseconds<br>
            • <strong>error_rate</strong>: Fraction of failed requests (0.000 = no errors)<br>
            • <strong>duration</strong>: How long the benchmark run took</p>
            
            <p><strong>Purpose:</strong><br>
            • <strong>Spot individual run anomalies</strong> before they get averaged out<br>
            • <strong>See run-to-run variation</strong> within the same configuration<br>
            • <strong>Identify trends</strong> across repetitions (getting better/worse over time)<br>
            • <strong>Validate data quality</strong> by checking if all runs are reasonably similar</p>"""
    
    # Group repetition metrics by config
    configs_sorted = sorted(rep_analysis['rep_metrics']['config'].unique(), reverse=True)
    for config in configs_sorted:
        config_data = rep_analysis['rep_metrics'][rep_analysis['rep_metrics']['config'] == config]
        config_data = config_data.sort_values('repetition', ascending=False)
        html_content += f"""
            <h4>Configuration: {config}</h4>
            {config_data.drop('config', axis=1).to_html(index=False, classes='table')}"""
    
    html_content += f"""
            
            <h3>Coefficient of Variation Analysis</h3>
            <p><strong>In the dashboard:</strong><br>
            • <strong>throughput_mean_cv</strong>: How consistent throughput is across repetitions<br>
            • <strong>latency_p50_cv, latency_p90_cv, latency_p99_cv</strong>: How consistent latency percentiles are<br>
            • <strong>cpu_avg_cv</strong>: How consistent average CPU utilization is across repetitions<br>
            • <strong>cpu_peak_cv</strong>: How consistent peak CPU spikes are across repetitions<br>
            • <strong>load_avg_1m_cv</strong>: How consistent system load averages are across repetitions<br>
            • <strong>total_queue_cv</strong>: How consistent thread pool queue depths are across repetitions<br>
            • <strong>total_rejected_cv</strong>: How consistent thread pool rejections are across repetitions<br>
            • <strong>max_queue_cv</strong>: How consistent peak queue depths are across repetitions</p>
            
            <p><strong>Interpretation:</strong><br>
            • <strong>CV &lt; 5%</strong>: Very consistent (good) - <span style="background-color: #d4edda; color: #155724; padding: 2px 4px;">Green</span><br>
            • <strong>CV 5-10%</strong>: Moderately consistent - <span style="background-color: #fff3cd; color: #856404; padding: 2px 4px;">Yellow</span><br>
            • <strong>CV &gt; 10%</strong>: High variability (investigate causes) - <span style="background-color: #f8d7da; color: #721c24; padding: 2px 4px;">Red</span></p>
            
            <p><strong>What Each Column Tells You:</strong><br>
            • <strong>Low throughput_mean_cv</strong>: Reliable, repeatable performance results<br>
            • <strong>Low latency_cv values</strong>: Predictable response times across runs<br>
            • <strong>Low cpu_avg_cv</strong>: Stable CPU usage patterns, no random spikes or bottlenecks<br>
            • <strong>Low cpu_peak_cv</strong>: Predictable peak CPU loads, consistent workload handling<br>
            • <strong>Low load_avg_1m_cv</strong>: Stable system load, no interference from other processes<br>
            • <strong>Low queue_cv values</strong>: Consistent thread pool behavior, no unexpected queueing or rejections<br>
            • <strong>High CV values (&gt;10%)</strong>: Inconsistent behavior - may indicate system interference, thermal throttling, resource contention, or configuration issues</p>"""
    
    # Generate color-coded CV table
    cv_df = rep_analysis['cv_analysis'].sort_index(ascending=False)
    
    def get_cv_color(val):
        if pd.isna(val) or val == 0:
            return ''
        elif val < 5:
            return 'background-color: #d4edda; color: #155724'  # Light green
        elif val <= 10:
            return 'background-color: #fff3cd; color: #856404'  # Light yellow
        else:
            return 'background-color: #f8d7da; color: #721c24'  # Light red
    
    # Build HTML table manually with color coding
    cv_table_html = '<table class="table"><thead><tr><th>Config</th>'
    for col in cv_df.columns:
        cv_table_html += f'<th>{col}</th>'
    cv_table_html += '</tr></thead><tbody>'
    
    for idx, row in cv_df.iterrows():
        cv_table_html += f'<tr><td>{idx}</td>'
        for col in cv_df.columns:
            val = row[col]
            style = get_cv_color(val)
            cv_table_html += f'<td style="{style}">{val:.2f}</td>'
        cv_table_html += '</tr>'
    cv_table_html += '</tbody></table>'
    
    html_content += f"""
            
            {cv_table_html}
            
            <h3>Outlier Detection (>2σ)</h3>
            <p>Identifies individual repetitions that deviate significantly from the mean within each configuration using statistical analysis (>2 standard deviations).</p>
            <p><strong>Purpose:</strong> Flag potentially unreliable runs caused by system interference, network issues, or other environmental factors that should be investigated or excluded from analysis.</p>
            {rep_analysis['outliers'].to_html(index=False, classes='table') if not rep_analysis['outliers'].empty else '<p>No outliers detected</p>'}
            
            <div class="metrics-grid">
                <div id="throughput_box"></div>
                <div id="latency_p90_box"></div>
            </div>
            <p><strong>Throughput and Latency Distribution:</strong> Box plots showing the spread and consistency of performance metrics across repetitions within each configuration. Wider boxes indicate more variability.</p>
            
            <div class="chart-container">
                <div id="scatter_plot"></div>
            </div>
            <p><strong>Throughput vs Latency Correlation:</strong> Scatter plot showing the relationship between throughput and P90 latency for each individual repetition. Helps identify performance trade-offs and optimal operating points.</p>
            
            <div class="chart-container">
                <div id="cpu_scatter_plot"></div>
            </div>
            <p><strong>Throughput vs CPU Correlation:</strong> Scatter plot showing the relationship between throughput and average CPU utilization for each repetition. Helps identify CPU bottlenecks and resource efficiency.</p>
            
            <div class="chart-container">
                <div id="queue_scatter_plot"></div>
            </div>
            <p><strong>Throughput vs Queue Depth Correlation:</strong> Scatter plot showing the relationship between throughput and thread pool queue depth for each repetition. Helps identify queueing bottlenecks and thread pool saturation.</p>
        </div>
        
        <!-- Tab 2: Run Level Analysis -->
        <div id="RunLevelAnalysis" class="tabcontent">
            <h2>Run Level Analysis - Performance Characteristics</h2>
            
            <h3>Aggregated Metrics (Mean ± Std Dev)</h3>
            {run_analysis['agg_metrics'].to_html(index=False, classes='table')}
            
            <div class="metrics-grid">
                <div id="resource_heatmap"></div>
                <div id="throughput_correlation"></div>
            </div>
            
            <div class="metrics-grid">
                <div id="latency_cpu_chart"></div>
                <div id="throughput_queue_chart"></div>
                <div id="throughput_latency_chart"></div>
            </div>
        </div>
        
        <!-- Tab 3: Config Comparison -->
        <div id="ConfigComparison" class="tabcontent">
            <h2>Config Level Comparison - Optimization Analysis</h2>
            
            <h3>Configuration Rankings</h3>
            {config_analysis['config_ranking'][['config', 'throughput_mean', 'latency_p99', 'efficiency', 'throughput_rank', 'latency_rank', 'efficiency_rank']].to_html(index=False, classes='table')}
            
            <h3>Scaling Analysis</h3>
            <table class="table">
                <tr><th>Dimension</th><th>Slope</th><th>R²</th><th>Efficiency</th></tr>"""
    
    for dimension, analysis in config_analysis['scaling_analysis'].items():
        html_content += f"""
                <tr><td>{dimension.replace('_', ' ').title()}</td><td>{analysis['slope']:.0f}</td><td>{analysis['r_squared']:.3f}</td><td>{analysis['efficiency']}</td></tr>"""
    
    html_content += f"""
            </table>
            
            <h3>Cost-Benefit Analysis</h3>
            {config_analysis['cost_benefit'].to_html(index=False, classes='table')}
            
            <div class="metrics-grid">
                <div id="scaling_3d"></div>
                <div id="pareto_frontier"></div>
            </div>
            
            <div class="chart-container">
                <div id="efficiency_curves"></div>
            </div>
        </div>
        
        <script>
            function openTab(evt, tabName) {{
                var i, tabcontent, tablinks;
                tabcontent = document.getElementsByClassName("tabcontent");
                for (i = 0; i < tabcontent.length; i++) {{
                    tabcontent[i].classList.remove("active");
                }}
                tablinks = document.getElementsByClassName("tablinks");
                for (i = 0; i < tablinks.length; i++) {{
                    tablinks[i].classList.remove("active");
                }}
                document.getElementById(tabName).classList.add("active");
                evt.currentTarget.classList.add("active");
            }}
            
            // Render Plotly charts
            {generate_plotly_js(rep_analysis, run_analysis, config_analysis)}
        </script>
    </body>
    </html>
    """
    
    # Save HTML dashboard
    os.makedirs(output_dir, exist_ok=True)
    with open(os.path.join(output_dir, 'performance_dashboard.html'), 'w') as f:
        f.write(html_content)
    
    return os.path.join(output_dir, 'performance_dashboard.html')

def generate_plotly_js(rep_analysis, run_analysis, config_analysis):
    """Generate JavaScript code for Plotly charts"""
    
    js_code = ""
    
    # Repetition analysis charts
    if 'throughput_mean' in rep_analysis['box_plots']:
        throughput_json = rep_analysis['box_plots']['throughput_mean'].to_json()
        js_code += f"Plotly.newPlot('throughput_box', {throughput_json});\n"
    
    if 'latency_p90' in rep_analysis['box_plots']:
        latency_json = rep_analysis['box_plots']['latency_p90'].to_json()
        js_code += f"Plotly.newPlot('latency_p90_box', {latency_json});\n"
    
    scatter_json = rep_analysis['scatter_plot'].to_json()
    js_code += f"Plotly.newPlot('scatter_plot', {scatter_json});\n"
    
    cpu_scatter_json = rep_analysis['cpu_scatter_plot'].to_json()
    js_code += f"Plotly.newPlot('cpu_scatter_plot', {cpu_scatter_json});\n"
    
    queue_scatter_json = rep_analysis['queue_scatter_plot'].to_json()
    js_code += f"Plotly.newPlot('queue_scatter_plot', {queue_scatter_json});\n"
    
    # Run level analysis charts
    heatmap_json = run_analysis['heatmap'].to_json()
    js_code += f"Plotly.newPlot('resource_heatmap', {heatmap_json});\n"
    
    corr_json = run_analysis['correlation'].to_json()
    js_code += f"Plotly.newPlot('throughput_correlation', {corr_json});\n"
    
    latency_cpu_json = run_analysis['latency_cpu'].to_json()
    js_code += f"Plotly.newPlot('latency_cpu_chart', {latency_cpu_json});\n"
    
    throughput_queue_json = run_analysis['throughput_queue'].to_json()
    js_code += f"Plotly.newPlot('throughput_queue_chart', {throughput_queue_json});\n"
    
    throughput_latency_json = run_analysis['throughput_latency'].to_json()
    js_code += f"Plotly.newPlot('throughput_latency_chart', {throughput_latency_json});\n"
    
    # Config comparison charts
    scaling_3d_json = config_analysis['scaling_3d'].to_json()
    js_code += f"Plotly.newPlot('scaling_3d', {scaling_3d_json});\n"
    
    pareto_json = config_analysis['pareto_frontier'].to_json()
    js_code += f"Plotly.newPlot('pareto_frontier', {pareto_json});\n"
    
    efficiency_json = config_analysis['efficiency_curves'].to_json()
    js_code += f"Plotly.newPlot('efficiency_curves', {efficiency_json});\n"
    
    return js_code

def main():
    # Use relative paths from script directory with dynamic page size detection
    script_dir = Path(__file__).parent
    
    # Detect page size to determine correct results directory
    import subprocess
    try:
        # Try to detect page size from system (assuming local analysis matches remote system)
        page_size = subprocess.check_output(['getconf', 'PAGESIZE'], text=True).strip()
        page_size_dir = "64k" if page_size == "65536" else "4k"
    except:
        # Default to 4k if detection fails
        page_size_dir = "4k"
    
    data_dir = script_dir / f"results/optimization/20251007_144856/c4a-64/{page_size_dir}/nyc_taxis"
    output_dir = script_dir / "analysis_output"
    
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
    
    # Generate three-level analysis
    print("Generating repetition analysis...")
    rep_analysis = create_repetition_analysis(df)
    
    print("Generating run level analysis...")
    run_analysis = create_run_level_analysis(df)
    
    print("Generating config comparison analysis...")
    config_analysis = create_config_comparison(df)
    
    # Generate HTML dashboard
    print("Creating comprehensive HTML dashboard...")
    dashboard_path = generate_html_dashboard(rep_analysis, run_analysis, config_analysis, output_dir)
    
    # Legacy analysis for backward compatibility
    outliers = analyze_repetitions(df)
    agg_stats = analyze_aggregates(df)
    generate_recommendations(df, agg_stats)
    
    # Save detailed results
    os.makedirs(output_dir, exist_ok=True)
    df.to_csv(os.path.join(output_dir, 'raw_results.csv'), index=False)
    rep_analysis['rep_metrics'].to_csv(os.path.join(output_dir, 'repetition_metrics.csv'), index=False)
    run_analysis['agg_metrics'].to_csv(os.path.join(output_dir, 'run_level_metrics.csv'), index=False)
    config_analysis['config_ranking'].to_csv(os.path.join(output_dir, 'config_rankings.csv'), index=False)
    
    print(f"\n=== ENHANCED DASHBOARD GENERATED ===")
    print(f"Dashboard: {dashboard_path}")
    print(f"Data files saved to: {output_dir}/")
    print("Files: raw_results.csv, repetition_metrics.csv, run_level_metrics.csv, config_rankings.csv")
    
    # Data quality summary
    print(f"\n=== DATA QUALITY SUMMARY ===")
    print(f"Total runs: {len(df)}")
    print(f"Configurations: {len(df['config'].unique())}")
    print(f"Outliers detected: {len(rep_analysis['outliers'])}")
    print(f"Error rate range: {df['error_rate'].min():.3f} - {df['error_rate'].max():.3f}")
    
    if not rep_analysis['outliers'].empty:
        print("\nOutlier details:")
        for _, outlier in rep_analysis['outliers'].iterrows():
            print(f"  {outlier['config']} rep {outlier['repetition']}: {outlier['metric']} outlier (z-score: {outlier['z_score']:.2f})")
    
    print(f"\nOpen {dashboard_path} in your browser to view the comprehensive analysis dashboard.")

if __name__ == "__main__":
    main()
