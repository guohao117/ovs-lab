#!/bin/bash

# =============================================================================
# Gateway Playground Flow Summary Script
# =============================================================================
# Displays formatted summary of OpenFlow rules for 2-layer gateway
# =============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Helper functions
print_header() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

print_subheader() {
    echo -e "\n${CYAN}--- $1 ---${NC}"
}

print_rule() {
    local priority="$1"
    local description="$2"
    local rule="$3"
    echo -e "${YELLOW}Priority $priority:${NC} $description"
    echo -e "${GREEN}  $rule${NC}"
}

# Get bridge name (default or from environment)
BRIDGE_NAME="${BRIDGE_NAME:-br-lab}"

# Check if bridge exists
if ! ovs-vsctl br-exists "$BRIDGE_NAME" 2>/dev/null; then
    echo -e "${RED}Error: Bridge $BRIDGE_NAME does not exist${NC}"
    echo "Please run the gateway playground first: ./lab.sh setup gateway"
    exit 1
fi

print_header "Gateway Playground OpenFlow Rules Summary"
echo -e "Bridge: ${CYAN}$BRIDGE_NAME${NC}"
echo -e "Connecting subnets: ${CYAN}10.10.0.0/24${NC} ↔ ${CYAN}10.20.0.0/24${NC}"

# ARP Proxy Rules
print_subheader "ARP Proxy Rules (Priority 300-250)"
echo "The switch responds to ARP requests for all managed IPs:"

flows=$(ovs-ofctl dump-flows "$BRIDGE_NAME" | grep "arp,arp_op=1" | sort -rn -k2 -t, | head -6)
if [[ -n "$flows" ]]; then
    echo "$flows" | while IFS= read -r flow; do
        if echo "$flow" | grep -q "arp_tpa=10.10.0.254"; then
            print_rule "300" "Gateway ARP (10.10.0.254)" "$(echo $flow | cut -d' ' -f2-)"
        elif echo "$flow" | grep -q "arp_tpa=10.20.0.254"; then
            print_rule "300" "Gateway ARP (10.20.0.254)" "$(echo $flow | cut -d' ' -f2-)"
        elif echo "$flow" | grep -q "arp_tpa=10.10.0.1"; then
            print_rule "250" "Container gw-c1 ARP (10.10.0.1)" "$(echo $flow | cut -d' ' -f2-)"
        elif echo "$flow" | grep -q "arp_tpa=10.10.0.2"; then
            print_rule "250" "Container gw-c2 ARP (10.10.0.2)" "$(echo $flow | cut -d' ' -f2-)"
        elif echo "$flow" | grep -q "arp_tpa=10.20.0.1"; then
            print_rule "250" "Container gw-c3 ARP (10.20.0.1)" "$(echo $flow | cut -d' ' -f2-)"
        elif echo "$flow" | grep -q "arp_tpa=10.20.0.2"; then
            print_rule "250" "Container gw-c4 ARP (10.20.0.2)" "$(echo $flow | cut -d' ' -f2-)"
        fi
    done
else
    echo -e "${RED}  No ARP proxy rules found${NC}"
fi

# ICMP Gateway Response Rules
print_subheader "ICMP Gateway Response Rules (Priority 220)"
echo "Virtual gateway responds to ICMP echo requests:"

icmp_flows=$(ovs-ofctl dump-flows "$BRIDGE_NAME" | grep "icmp,icmp_type=8" | sort -rn -k2 -t,)
if [[ -n "$icmp_flows" ]]; then
    echo "$icmp_flows" | while IFS= read -r flow; do
        if echo "$flow" | grep -q "nw_dst=10.10.0.254"; then
            print_rule "220" "ICMP echo reply for 10.10.0.254" "$(echo $flow | cut -d' ' -f2-)"
        elif echo "$flow" | grep -q "nw_dst=10.20.0.254"; then
            print_rule "220" "ICMP echo reply for 10.20.0.254" "$(echo $flow | cut -d' ' -f2-)"
        fi
    done
else
    echo -e "${RED}  No ICMP response rules found${NC}"
fi

# L3 Routing Rules
print_subheader "L3 Routing Rules (Priority 220)"
echo "Cross-subnet traffic is routed through the gateway:"

l3_flows=$(ovs-ofctl dump-flows "$BRIDGE_NAME" | grep -E "dl_dst=02:ff:00:00:00:fe.*nw_src=10\.(10|20)\.0\.0/24" | sort -rn -k2 -t,)
if [[ -n "$l3_flows" ]]; then
    echo "$l3_flows" | while IFS= read -r flow; do
        if echo "$flow" | grep -q "nw_src=10.10.0.0/24.*nw_dst=10.20.0.1"; then
            print_rule "220" "Route 10.10.0.0/24 → gw-c3 (10.20.0.1)" "$(echo $flow | cut -d' ' -f2-)"
        elif echo "$flow" | grep -q "nw_src=10.10.0.0/24.*nw_dst=10.20.0.2"; then
            print_rule "220" "Route 10.10.0.0/24 → gw-c4 (10.20.0.2)" "$(echo $flow | cut -d' ' -f2-)"
        elif echo "$flow" | grep -q "nw_src=10.20.0.0/24.*nw_dst=10.10.0.1"; then
            print_rule "220" "Route 10.20.0.0/24 → gw-c1 (10.10.0.1)" "$(echo $flow | cut -d' ' -f2-)"
        elif echo "$flow" | grep -q "nw_src=10.20.0.0/24.*nw_dst=10.10.0.2"; then
            print_rule "220" "Route 10.20.0.0/24 → gw-c2 (10.10.0.2)" "$(echo $flow | cut -d' ' -f2-)"
        elif echo "$flow" | grep -q "actions=drop"; then
            print_rule "220" "Drop unknown cross-subnet traffic" "$(echo $flow | cut -d' ' -f2-)"
        fi
    done
else
    echo -e "${RED}  No L3 routing rules found${NC}"
fi

# Gateway forwarding rules
gw_flows=$(ovs-ofctl dump-flows "$BRIDGE_NAME" | grep "in_port=254" | grep -E "nw_dst=10\.(10|20)\.0\.[12]" | sort -rn -k2 -t,)
if [[ -n "$gw_flows" ]]; then
    echo "$gw_flows" | while IFS= read -r flow; do
        if echo "$flow" | grep -q "nw_dst=10.10.0"; then
            target=$(echo "$flow" | grep -o "nw_dst=10\.10\.0\.[12]" | cut -d'=' -f2)
            print_rule "190" "Gateway forward to $target" "$(echo $flow | cut -d' ' -f2-)"
        elif echo "$flow" | grep -q "nw_dst=10.20.0"; then
            target=$(echo "$flow" | grep -o "nw_dst=10\.20\.0\.[12]" | cut -d'=' -f2)
            print_rule "190" "Gateway forward to $target" "$(echo $flow | cut -d' ' -f2-)"
        fi
    done
fi

# L2 Forwarding Rules
print_subheader "L2 Forwarding Rules (Priority 200)"
echo "Direct MAC-based forwarding within subnets:"

l2_flows=$(ovs-ofctl dump-flows "$BRIDGE_NAME" | grep -E "dl_dst=02:(10|20|ff)" | sort -rn -k2 -t,)
if [[ -n "$l2_flows" ]]; then
    echo "$l2_flows" | while IFS= read -r flow; do
        if echo "$flow" | grep -q "dl_dst=02:10:00:00:00:01"; then
            print_rule "150" "Forward to gw-c1 (02:10:00:00:00:01)" "$(echo $flow | cut -d' ' -f2-)"
        elif echo "$flow" | grep -q "dl_dst=02:10:00:00:00:02"; then
            print_rule "150" "Forward to gw-c2 (02:10:00:00:00:02)" "$(echo $flow | cut -d' ' -f2-)"
        elif echo "$flow" | grep -q "dl_dst=02:20:00:00:00:01"; then
            print_rule "150" "Forward to gw-c3 (02:20:00:00:00:01)" "$(echo $flow | cut -d' ' -f2-)"
        elif echo "$flow" | grep -q "dl_dst=02:20:00:00:00:02"; then
            print_rule "200" "Forward to gw-c4 (02:20:00:00:00:02)" "$(echo $flow | cut -d' ' -f2-)"
        elif echo "$flow" | grep -q "dl_dst=02:ff:00:00:00:fe"; then
            print_rule "200" "Forward to gateway (02:ff:00:00:00:fe)" "$(echo $flow | cut -d' ' -f2-)"
        fi
    done
else
    echo -e "${RED}  No L2 forwarding rules found${NC}"
fi

# Security Rules
print_subheader "Security Rules (Priority 150-100)"
echo "Traffic isolation and security policies:"

drop_flows=$(ovs-ofctl dump-flows "$BRIDGE_NAME" | grep "actions=drop" | sort -rn -k2 -t,)
drop_count=$(echo "$drop_flows" | wc -l)
if [[ $drop_count -gt 0 ]]; then
    echo -e "${YELLOW}Priority 150:${NC} Drop direct cross-subnet L2 attempts (${drop_count} rules)"
    echo -e "${GREEN}  Prevents bypassing gateway for inter-subnet communication${NC}"

    unknown_arp=$(echo "$drop_flows" | grep "arp,arp_op=1" | head -1)
    if [[ -n "$unknown_arp" ]]; then
        print_rule "100" "Drop unknown ARP requests" "$(echo $unknown_arp | cut -d' ' -f2-)"
    fi
else
    echo -e "${RED}  No security rules found${NC}"
fi

# Default Rules
print_subheader "Default Rules (Priority 50-10)"
echo "Fallback behavior for unmatched traffic:"

default_flows=$(ovs-ofctl dump-flows "$BRIDGE_NAME" | grep -E "priority=(50|10)" | sort -rn -k2 -t,)
if [[ -n "$default_flows" ]]; then
    echo "$default_flows" | while IFS= read -r flow; do
        if echo "$flow" | grep -q "actions=flood"; then
            print_rule "50" "Flood broadcast/multicast traffic" "$(echo $flow | cut -d' ' -f2-)"
        elif echo "$flow" | grep -q "actions=drop"; then
            print_rule "10" "Drop unknown unicast traffic" "$(echo $flow | cut -d' ' -f2-)"
        fi
    done
else
    echo -e "${RED}  No default rules found${NC}"
fi

# Flow Statistics
print_subheader "Flow Statistics"
echo "Traffic counters for gateway flows:"

total_flows=$(ovs-ofctl dump-flows "$BRIDGE_NAME" | wc -l)
arp_flows=$(ovs-ofctl dump-flows "$BRIDGE_NAME" | grep "arp" | wc -l)
ip_flows=$(ovs-ofctl dump-flows "$BRIDGE_NAME" | grep -E "nw_(src|dst)" | wc -l)

echo -e "  Total flows: ${CYAN}$total_flows${NC}"
echo -e "  ARP flows: ${CYAN}$arp_flows${NC}"
echo -e "  IP flows: ${CYAN}$ip_flows${NC}"

# Active flows (with packet counts > 0)
active_flows=$(ovs-ofctl dump-flows "$BRIDGE_NAME" | grep -v "n_packets=0" | wc -l)
echo -e "  Active flows (with traffic): ${CYAN}$active_flows${NC}"

# Top traffic flows
print_subheader "Top Traffic Flows"
echo "Flows with highest packet counts:"

ovs-ofctl dump-flows "$BRIDGE_NAME" | grep -v "n_packets=0" | sort -rn -k1.10 | head -5 | while IFS= read -r flow; do
    packets=$(echo "$flow" | grep -o "n_packets=[0-9]*" | cut -d'=' -f2)
    bytes=$(echo "$flow" | grep -o "n_bytes=[0-9]*" | cut -d'=' -f2)
    rule=$(echo "$flow" | cut -d' ' -f2- | cut -c1-60)
    echo -e "  ${GREEN}$packets packets, $bytes bytes:${NC} $rule..."
done

# Port statistics
print_subheader "Port Statistics"
echo "Container port mappings and traffic:"

echo -e "  ${CYAN}Container → OpenFlow Port Mapping:${NC}"
echo "    gw-c1: port 10 (10.10.0.1)"
echo "    gw-c2: port 11 (10.10.0.2)"
echo "    gw-c3: port 20 (10.20.0.1)"
echo "    gw-c4: port 21 (10.20.0.2)"
echo "    gw-gateway: port 254 (10.10.0.254, 10.20.0.254)"

print_header "Summary"
echo -e "Gateway playground is configured with ${GREEN}$total_flows total OpenFlow rules${NC}"
echo -e "Supporting ${CYAN}L2 forwarding${NC} within subnets and ${CYAN}L3 routing${NC} between subnets"
echo -e "All traffic flows through the gateway for inter-subnet communication"

# Usage tips
echo -e "\n${YELLOW}Usage Tips:${NC}"
echo "  • Test connectivity: ./playgrounds/gateway/test-gateway.sh"
echo "  • Monitor traffic: ./lab.sh exec --tty gw-gateway tcpdump -i eth0 -n"
echo "  • View live stats: watch -n 1 'ovs-ofctl dump-flows $BRIDGE_NAME | head -20'"
echo "  • Trace packets: ovs-appctl ofproto/trace $BRIDGE_NAME <flow_spec>"
