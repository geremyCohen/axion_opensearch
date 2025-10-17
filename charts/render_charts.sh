#!/bin/bash

# Check if OS_DATA is set
if [ -z "$OS_DATA" ]; then
    echo "Error: OS_DATA environment variable not set"
    echo "Usage: OS_DATA=/path/to/data ./render_charts.sh"
    exit 1
fi

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Rendering charts from data: $OS_DATA"

# Generate combined dashboard
echo "Generating combined dashboard..."
python3 "$SCRIPT_DIR/generate_combined_dashboard.py" "$OS_DATA"

# Update UI experiments if the script exists
if [ -f "$SCRIPT_DIR/update_ui_experiments.py" ]; then
    echo "Updating UI experiments..."
    python3 "$SCRIPT_DIR/update_ui_experiments.py"
fi

echo "Charts rendered successfully in $SCRIPT_DIR/output/"
