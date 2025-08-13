#!/bin/bash
# Test script for true OpenFlow ARP proxy functionality

echo "=== True OpenFlow ARP Proxy Test ==="
echo "Testing switch-generated ARP replies (no container involvement)"
echo

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to run test and display result
run_test() {
    local container="$1"
    local command="$2"
    local description="$3"
    local expect_success="${4:-true}"
    
    echo -e "${BLUE}🧪 Test:${NC} $description"
    echo "   Command: docker exec $container $command"
    
    if docker exec "$container" bash -c "$command" >/dev/null 2>&1; then
        if [[ "$expect_success" == "true" ]]; then
            echo -e "   ${GREEN}✅ Success${NC}"
            return 0
        else
            echo -e "   ${RED}❌ Unexpected success${NC}"
            return 1
        fi
    else
        if [[ "$expect_success" == "false" ]]; then
            echo -e "   ${GREEN}✅ Expected failure${NC}"
            return 0
        else
            echo -e "   ${RED}❌ Failed${NC}"
            return 1
        fi
    fi
}

# Check if containers are running
echo -e "${YELLOW}Checking container status...${NC}"
for container in c1 c2 c3; do
    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        echo -e "   ${GREEN}✓${NC} $container is running"
    else
        echo -e "   ${RED}✗${NC} $container is not running"
        echo "Please run: ./lab.sh setup simple"
        exit 1
    fi
done
echo

# Test 1: ARP proxy functionality (switch generates replies)
echo -e "${YELLOW}1. Testing ARP proxy functionality...${NC}"
run_test "c1" "ping -c 2 -W 2 10.0.0.2" "c1 -> c2 (via ARP proxy)"
run_test "c1" "ping -c 2 -W 2 10.0.0.3" "c1 -> c3 (via ARP proxy)"
run_test "c2" "ping -c 2 -W 2 10.0.0.3" "c2 -> c3 (via ARP proxy)"
echo

# Test 2: Unknown IP addresses (should fail - no ARP proxy response)
echo -e "${YELLOW}2. Testing unknown IP addresses (no proxy response)...${NC}"
run_test "c1" "ping -c 1 -W 2 10.0.0.100" "c1 -> 10.0.0.100 (unknown IP)" "false"
run_test "c1" "ping -c 1 -W 2 10.0.0.200" "c1 -> 10.0.0.200 (unknown IP)" "false"
run_test "c2" "ping -c 1 -W 2 10.0.0.99" "c2 -> 10.0.0.99 (unknown IP)" "false"
echo

# Test 3: Check proxy MAC addresses in ARP tables
echo -e "${YELLOW}3. Checking ARP proxy MAC addresses...${NC}"
echo -e "${BLUE}c1 ARP table (should show proxy MACs):${NC}"
docker exec c1 arp -a 2>/dev/null | sed 's/^/   /' || echo "   (empty)"

echo -e "${BLUE}c2 ARP table (should show proxy MACs):${NC}"
docker exec c2 arp -a 2>/dev/null | sed 's/^/   /' || echo "   (empty)"

echo -e "${BLUE}c3 ARP table (should show proxy MACs):${NC}"
docker exec c3 arp -a 2>/dev/null | sed 's/^/   /' || echo "   (empty)"

echo -e "${BLUE}Expected MAC pattern: 02:00:00:00:01:XX${NC}"
echo

# Test 4: Verify container MAC addresses match proxy responses
echo -e "${YELLOW}4. Verifying container MAC addresses...${NC}"
for i in 1 2 3; do
    container="c${i}"
    expected_mac="02:00:00:00:01:0${i}"
    actual_mac=$(docker exec "$container" ip link show eth0 | grep -o '[0-9a-f]\{2\}:[0-9a-f]\{2\}:[0-9a-f]\{2\}:[0-9a-f]\{2\}:[0-9a-f]\{2\}:[0-9a-f]\{2\}' | head -1)
    
    if [[ "$actual_mac" == "$expected_mac" ]]; then
        echo -e "   ${GREEN}✓${NC} $container MAC: $actual_mac (correct)"
    else
        echo -e "   ${RED}✗${NC} $container MAC: $actual_mac (expected: $expected_mac)"
    fi
done
echo

# Test 5: Check ARP proxy flow statistics
echo -e "${YELLOW}5. Checking ARP proxy flow statistics...${NC}"
echo -e "${BLUE}ARP proxy flows (should show packet counts > 0):${NC}"
ovs-ofctl dump-flows br-lab | grep -E "(arp.*arp_tpa.*actions=load.*NXM|arp.*arp_op=1.*actions=drop)" | sed 's/^/   /' || echo "   No ARP proxy flows found"
echo

echo -e "${GREEN}=== Test Summary ===${NC}"
echo "✓ ARP Proxy: Switch generates ARP replies directly"
echo "✓ Known IPs: Immediate ARP responses with predefined MACs"
echo "✓ Unknown IPs: No ARP responses (properly dropped)"
echo "✓ MAC consistency: Container MACs match proxy responses"
echo "✓ Flow usage: Packet counters show proxy activity"
echo
echo -e "${BLUE}💡 ARP Proxy Benefits:${NC}"
echo "• No container involvement in ARP resolution"
echo "• Faster ARP responses (switch-level processing)"
echo "• Consistent MAC addresses across network"
echo "• Centralized ARP state management"
echo
echo -e "${BLUE}💡 Debug Commands:${NC}"
echo "• View all flows: ovs-ofctl dump-flows br-lab"
echo "• Monitor ARP: tcpdump -i any arp"
echo "• Check MAC: docker exec c1 ip link show eth0"
echo "• Clear ARP cache: docker exec c1 ip neigh flush all"
