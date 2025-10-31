#!/bin/bash
# Start 3-node TigerChat cluster on localhost

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BINARY="$PROJECT_ROOT/zig-out/bin/tigerchat"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "🐅 Starting TigerChat 3-node cluster..."
echo

# Build binary if needed
if [ ! -f "$BINARY" ]; then
    echo "Building tigerchat binary..."
    cd "$PROJECT_ROOT"
    zig build
    echo
fi

# Kill any existing instances
pkill -f "tigerchat --config" || true
sleep 1

# Start replica 0 (primary)
echo -e "${GREEN}Starting Replica 0 (primary) on port 3000${NC}"
"$BINARY" --config "$PROJECT_ROOT/configs/replica0.conf" > /tmp/tigerchat-replica0.log 2>&1 &
REPLICA0_PID=$!
echo "  PID: $REPLICA0_PID"
sleep 1

# Start replica 1 (backup)
echo -e "${GREEN}Starting Replica 1 (backup) on port 3001${NC}"
"$BINARY" --config "$PROJECT_ROOT/configs/replica1.conf" > /tmp/tigerchat-replica1.log 2>&1 &
REPLICA1_PID=$!
echo "  PID: $REPLICA1_PID"
sleep 1

# Start replica 2 (backup)
echo -e "${GREEN}Starting Replica 2 (backup) on port 3002${NC}"
"$BINARY" --config "$PROJECT_ROOT/configs/replica2.conf" > /tmp/tigerchat-replica2.log 2>&1 &
REPLICA2_PID=$!
echo "  PID: $REPLICA2_PID"
sleep 1

echo
echo "✓ 3-node cluster started"
echo
echo -e "${YELLOW}Processes:${NC}"
ps aux | grep tigerchat | grep -v grep || true
echo
echo -e "${YELLOW}Logs:${NC}"
echo "  Replica 0: /tmp/tigerchat-replica0.log"
echo "  Replica 1: /tmp/tigerchat-replica1.log"
echo "  Replica 2: /tmp/tigerchat-replica2.log"
echo
echo -e "${YELLOW}To stop cluster:${NC}"
echo "  ./scripts/stop-cluster.sh"
echo "  or: pkill -f tigerchat"
echo
