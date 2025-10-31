#!/bin/bash
# Stop TigerChat cluster

echo "🐅 Stopping TigerChat cluster..."
pkill -SIGINT -f "tigerchat --config" || echo "No running instances found"
sleep 1
echo "✓ Cluster stopped"
echo
echo "Logs preserved in /tmp/tigerchat-replica*.log"
