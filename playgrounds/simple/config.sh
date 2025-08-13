#!/bin/bash

# =============================================================================
# Simple Playground Configuration
# =============================================================================
# A basic 3-container setup for OVS testing and experimentation
# =============================================================================

# Load OVS helper functions
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SCRIPT_DIR/../../lib/ovs-helpers.sh"

# Playground metadata
PLAYGROUND_NAME="Simple 3-Container Lab with OpenFlow ARP Proxy"
PLAYGROUND_DESCRIPTION="3 containers with true OpenFlow ARP proxy - switch generates ARP replies"
PLAYGROUND_VERSION="1.1"

# Container configuration
CONTAINERS=(c1 c2 c3)

# Network configuration - single subnet with ARP proxy demo
# Format: ["container_name"]="ip_address/netmask:gateway"
CONTAINER_CONFIG["c1"]="10.0.0.1/24:10.0.0.254"
CONTAINER_CONFIG["c2"]="10.0.0.2/24:10.0.0.254"
CONTAINER_CONFIG["c3"]="10.0.0.3/24:10.0.0.254"

# Container ofport mapping (for consistent OpenFlow port numbers)
# Format: ["container_name"]="ofport_number"
CONTAINER_OFPORT["c1"]="101"
CONTAINER_OFPORT["c2"]="102"
CONTAINER_OFPORT["c3"]="103"

# Optional: Container image override (defaults to nicolaka/netshoot:latest)
# declare -A CONTAINER_IMAGE=(
#     ["c1"]="nicolaka/netshoot:latest"
#     ["c2"]="nicolaka/netshoot:latest"
#     ["c3"]="nicolaka/netshoot:latest"
# )

# Optional: Additional docker run arguments
# declare -A CONTAINER_ARGS=(
#     ["c1"]="--privileged"
#     ["c2"]="--privileged"
#     ["c3"]="--privileged"
# )

# Bridge configuration (optional, defaults to br-lab)
# BRIDGE_NAME="br-simple"

# Playground-specific setup function (optional)
playground_setup() {
    echo "Setting up true OpenFlow ARP proxy..."
    # The flows will be automatically applied from flows/ directory
    # This demonstrates OpenFlow switch generating ARP replies directly
    
    # Set container MAC addresses to match ARP proxy responses
    echo "Configuring container MAC addresses for ARP proxy..."
    docker exec c1 ip link set eth0 down 2>/dev/null || true
    docker exec c1 ip link set eth0 address 02:00:00:00:01:01 2>/dev/null || true
    docker exec c1 ip link set eth0 up 2>/dev/null || true
    
    docker exec c2 ip link set eth0 down 2>/dev/null || true
    docker exec c2 ip link set eth0 address 02:00:00:00:01:02 2>/dev/null || true
    docker exec c2 ip link set eth0 up 2>/dev/null || true
    
    docker exec c3 ip link set eth0 down 2>/dev/null || true
    docker exec c3 ip link set eth0 address 02:00:00:00:01:03 2>/dev/null || true
    docker exec c3 ip link set eth0 up 2>/dev/null || true
    
    echo "✓ ARP proxy MAC addresses configured"
    return 0
}

# Playground-specific cleanup function (optional)
playground_cleanup() {
    echo "Cleaning up Simple playground..."
    # Add any playground-specific cleanup here
    return 0
}

# Help text for this playground
playground_help() {
    cat << EOF
Simple Playground with True OpenFlow ARP Proxy Help
==================================================

This playground demonstrates a true OpenFlow ARP proxy where the switch itself
generates ARP replies without forwarding requests to containers:

Containers:
  • c1 (10.0.0.1/24) - MAC 02:00:00:00:01:01 - ofport 101
  • c2 (10.0.0.2/24) - MAC 02:00:00:00:01:02 - ofport 102  
  • c3 (10.0.0.3/24) - MAC 02:00:00:00:01:03 - ofport 103

True ARP Proxy Features:
  • Switch generates ARP replies directly (no container involvement)
  • Uses NXM field manipulation to craft proper ARP responses
  • Pre-configured MAC addresses for each container
  • Drops ARP requests for unknown IP addresses
  • Pure OpenFlow implementation (no external controller)

Basic usage:
  1. Setup environment: ./lab.sh setup simple
  2. Test connectivity: ./lab.sh exec c1 ping 10.0.0.2
  3. Check ARP table: ./lab.sh exec c1 arp -a
  4. View flows: ovs-ofctl dump-flows br-lab

Expected behavior:
  • ARP requests for c1, c2, c3: Switch generates immediate ARP replies
  • ARP requests for unknown IPs: Dropped by switch (no response)
  • Ping between containers: Works using proxy-provided MAC addresses
  • ARP tables: Show consistent proxy MAC addresses

OpenFlow ARP Proxy Implementation:
  Priority 200: Generate ARP replies for known containers
    - Convert ARP request to ARP reply (arp_op: 1->2)
    - Swap source/target fields appropriately  
    - Insert predefined MAC addresses
    - Return packet to requesting port
  Priority 150: Drop ARP requests for unknown IPs
  Priority 50:  Normal L2 learning for all other traffic

Testing true ARP proxy:
  # Test normal connectivity (should work via ARP proxy)
  ./lab.sh exec c1 ping -c 2 10.0.0.2
  ./lab.sh exec c1 ping -c 2 10.0.0.3
  
  # Check ARP table (should show proxy MACs consistently)
  ./lab.sh exec c1 arp -a
  # Expected: 02:00:00:00:01:02, 02:00:00:00:01:03
  
  # Test unknown IP (should timeout - no ARP response)
  ./lab.sh exec c1 ping -c 1 10.0.0.100  # Should fail
  
  # View flow statistics (should show packet counts)
  ovs-ofctl dump-flows br-lab | grep arp

Key difference from forwarding approach:
  • No packets sent to containers for ARP resolution
  • Switch maintains ARP state internally via flows
  • Consistent MAC addresses across all containers
  • Better performance (no container network stack involvement)

EOF
}
