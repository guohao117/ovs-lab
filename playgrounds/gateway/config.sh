#!/bin/bash

# =============================================================================
# Gateway Playground Configuration
# =============================================================================
# A 4-container setup demonstrating pure OpenFlow 2-layer gateway functionality
# connecting subnet 10.10.0.0/24 to subnet 10.20.0.0/24 without gateway container
# =============================================================================

# Load OVS helper functions
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SCRIPT_DIR/../../lib/ovs-helpers.sh"

# Playground metadata
PLAYGROUND_NAME="Pure OpenFlow 2-Layer Gateway Lab"
PLAYGROUND_DESCRIPTION="4-container setup with pure OpenFlow gateway connecting two subnets (10.10.0.0/24 ↔ 10.20.0.0/24)"
PLAYGROUND_VERSION="1.0"

# Container configuration - Pure OpenFlow gateway, no gateway container
CONTAINERS=(c1 c2 c3 c4)

# Network configuration
# Format: ["container_name"]="ip_address/netmask:gateway"
# Subnet 10.10.0.0/24
CONTAINER_CONFIG["c1"]="10.10.0.1/24:10.10.0.254"
CONTAINER_CONFIG["c2"]="10.10.0.2/24:10.10.0.254"
# Subnet 10.20.0.0/24
CONTAINER_CONFIG["c3"]="10.20.0.1/24:10.20.0.254"
CONTAINER_CONFIG["c4"]="10.20.0.2/24:10.20.0.254"

# Container ofport mapping (for consistent OpenFlow port numbers)
# Format: ["container_name"]="ofport_number"
CONTAINER_OFPORT["c1"]="10"
CONTAINER_OFPORT["c2"]="11"
CONTAINER_OFPORT["c3"]="20"
CONTAINER_OFPORT["c4"]="21"

# Playground-specific setup function
playground_setup() {
    echo "Setting up pure OpenFlow 2-layer gateway..."
    # All gateway functionality is implemented in OpenFlow rules
    # No container-based gateway needed

    # Set container MAC addresses to match OpenFlow ARP proxy responses
    echo "Configuring container MAC addresses for OpenFlow gateway..."
    docker exec c1 ip link set eth0 down 2>/dev/null || true
    docker exec c1 ip link set eth0 address 02:10:00:00:00:01 2>/dev/null || true
    docker exec c1 ip link set eth0 up 2>/dev/null || true

    docker exec c2 ip link set eth0 down 2>/dev/null || true
    docker exec c2 ip link set eth0 address 02:10:00:00:00:02 2>/dev/null || true
    docker exec c2 ip link set eth0 up 2>/dev/null || true

    docker exec c3 ip link set eth0 down 2>/dev/null || true
    docker exec c3 ip link set eth0 address 02:20:00:00:00:01 2>/dev/null || true
    docker exec c3 ip link set eth0 up 2>/dev/null || true

    docker exec c4 ip link set eth0 down 2>/dev/null || true
    docker exec c4 ip link set eth0 address 02:20:00:00:00:02 2>/dev/null || true
    docker exec c4 ip link set eth0 up 2>/dev/null || true

    # Add routes for cross-subnet communication pointing to OpenFlow gateway
    echo "Configuring cross-subnet routes..."
    docker exec c1 ip route add 10.20.0.0/24 via 10.10.0.254 2>/dev/null || true
    docker exec c2 ip route add 10.20.0.0/24 via 10.10.0.254 2>/dev/null || true
    docker exec c3 ip route add 10.10.0.0/24 via 10.20.0.254 2>/dev/null || true
    docker exec c4 ip route add 10.10.0.0/24 via 10.20.0.254 2>/dev/null || true

    # Static OpenFlow rules will be applied from flows/ directory
    echo "Static OpenFlow rules will handle gateway functionality..."

    echo "  Cross-subnet routes:"
    echo "    c1 → 10.20.0.0/24: $(docker exec c1 ip route | grep "10.20.0.0/24" || echo "not configured")"
    echo "    c3 → 10.10.0.0/24: $(docker exec c3 ip route | grep "10.10.0.0/24" || echo "not configured")"

    echo "✓ Pure OpenFlow gateway configuration complete"
    return 0
}

# Playground-specific cleanup function
playground_cleanup() {
    echo "Cleaning up gateway playground..."
    # Container networking will be cleaned up when containers are removed
    return 0
}

# Help text for this playground
playground_help() {
    cat << EOF
2-Layer Gateway Playground Help
===============================

This playground demonstrates OpenFlow 2-layer gateway functionality connecting
two subnets through a central gateway container.

Network Topology:
┌─────────────────────────────────────────────────────────────────┐
│                    Subnet 10.10.0.0/24                         │
│  ┌─────────┐    ┌─────────┐              ┌─────────────────┐   │
│  │   c1    │    │   c2    │          OpenFlow Switch       │   │
│  │10.10.0.1│    │10.10.0.2│         (Pure OpenFlow        │   │
│  │ port 10 │    │ port 11 │          Gateway Logic)        │   │
│  └─────────┘    └─────────┘         10.10.0.254 ↕ 10.20.0.254  │
│                                                              │   │
└──────────────────────────────┬────────────────────────────────┘
                               │
┌──────────────────────────────┴────────────────────────────────┐
│                    Subnet 10.20.0.0/24                        │
│                                         OpenFlow Switch       │   │
│  ┌─────────┐    ┌─────────┐            (Same switch,         │   │
│  │   c3    │    │   c4    │             gateway logic       │   │
│  │10.20.0.1│    │10.20.0.2│             implemented in      │   │
│  │ port 20 │    │ port 21 │             flow rules)         │   │
│  └─────────┘    └─────────┘                                    │
└─────────────────────────────────────────────────────────────────┘

Containers:
  Subnet 10.10.0.0/24:
    • c1 (10.10.0.1/24) - MAC 02:10:00:00:00:01 - ofport 10
    • c2 (10.10.0.2/24) - MAC 02:10:00:00:00:02 - ofport 11

  Subnet 10.20.0.0/24:
    • c3 (10.20.0.1/24) - MAC 02:20:00:00:00:01 - ofport 20
    • c4 (10.20.0.2/24) - MAC 02:20:00:00:00:02 - ofport 21

  OpenFlow Gateway (Virtual):
    • 10.10.0.254 and 10.20.0.254 are virtual IPs handled by OpenFlow rules
    • No physical gateway container - all logic in flow table
    • Gateway MAC: 02:ff:00:00:00:fe (used in OpenFlow ARP responses)

Pure OpenFlow Gateway Features:
  • Virtual ARP proxy for gateway IPs (10.10.0.254, 10.20.0.254)
  • MAC-based L2 forwarding within subnets
  • OpenFlow-based L3 routing between subnets (no container forwarding)
  • MAC rewriting and TTL decrement in OpenFlow pipeline
  • Zero-touch gateway - all logic in flow rules

Basic usage:
  1. Setup environment: ./lab.sh setup gateway
  2. Test intra-subnet: ./lab.sh exec gw-c1 ping 10.10.0.2
  3. Test inter-subnet: ./lab.sh exec gw-c1 ping 10.20.0.1
  4. View flows: ovs-ofctl dump-flows br-lab

Expected behavior:
  • Same subnet connectivity: c1 ↔ c2, c3 ↔ c4
  • Cross subnet connectivity: c1 ↔ c3, c1 ↔ c4, etc.
  • Gateway responds to ARP for .254 addresses in both subnets
  • Traffic routing through gateway with MAC rewriting

Testing scenarios:
  # Test same subnet connectivity (L2 forwarding)
  ./lab.sh exec c1 ping -c 3 10.10.0.2
  ./lab.sh exec c3 ping -c 3 10.20.0.2

  # Test cross subnet connectivity (L3 routing via gateway)
  ./lab.sh exec c1 ping -c 3 10.20.0.1
  ./lab.sh exec c3 ping -c 3 10.10.0.1

  # Test gateway reachability
  ./lab.sh exec c1 ping -c 3 10.10.0.254
  ./lab.sh exec c3 ping -c 3 10.20.0.254

  # Check ARP tables (should show gateway MACs for cross-subnet)
  ./lab.sh exec c1 arp -a
  ./lab.sh exec c3 arp -a

  # Check routing tables
  ./lab.sh exec c1 ip route
  ./lab.sh exec c3 ip route

  # View flow statistics
  ovs-ofctl dump-flows br-lab | grep -E "(arp|nw_dst)"

Advanced testing:
  # Traceroute to see routing path
  ./lab.sh exec c1 traceroute 10.20.0.1

  # Interactive troubleshooting
  ./lab.sh exec -it c1 bash

Key OpenFlow implementation details:
  • High priority ARP proxy rules for gateway IPs (.254)
  • MAC learning and forwarding for L2 traffic within subnets
  • IP routing rules for cross-subnet traffic via gateway
  • MAC rewriting for proper L2/L3 boundary handling
  • Drop rules for invalid cross-subnet direct L2 attempts

EOF
}
