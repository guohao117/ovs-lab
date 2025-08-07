#!/bin/bash

# =============================================================================
# VLAN Playground Configuration
# =============================================================================
# A 6-container setup demonstrating VLAN segmentation with OVS
# =============================================================================

# Load OVS helper functions
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SCRIPT_DIR/../../lib/ovs-helpers.sh"

# Playground metadata
PLAYGROUND_NAME="VLAN Segmentation Lab"
PLAYGROUND_DESCRIPTION="6-container setup with VLAN tags for network segmentation testing"
PLAYGROUND_VERSION="1.0"

# Container configuration
CONTAINERS=(vlan10-c1 vlan10-c2 vlan20-c1 vlan20-c2 trunk-c1 trunk-c2)

# Network configuration
# Format: ["container_name"]="ip_address/netmask:gateway"
CONTAINER_CONFIG["vlan10-c1"]="10.10.0.1/24:10.10.0.254"
CONTAINER_CONFIG["vlan10-c2"]="10.10.0.2/24:10.10.0.254"
CONTAINER_CONFIG["vlan20-c1"]="10.20.0.1/24:10.20.0.254"
CONTAINER_CONFIG["vlan20-c2"]="10.20.0.2/24:10.20.0.254"
CONTAINER_CONFIG["trunk-c1"]="192.168.1.1/24:192.168.1.254"
CONTAINER_CONFIG["trunk-c2"]="192.168.1.2/24:192.168.1.254"

# Container ofport mapping (for consistent OpenFlow port numbers)
# Format: ["container_name"]="ofport_number"
CONTAINER_OFPORT["vlan10-c1"]="10"
CONTAINER_OFPORT["vlan10-c2"]="11"
CONTAINER_OFPORT["vlan20-c1"]="20"
CONTAINER_OFPORT["vlan20-c2"]="21"
CONTAINER_OFPORT["trunk-c1"]="100"
CONTAINER_OFPORT["trunk-c2"]="101"

# VLAN configuration
# Format: ["container_name"]="vlan_id:mode"
# Modes: access, trunk, native
declare -A CONTAINER_VLAN=(
    ["vlan10-c1"]="10:access"
    ["vlan10-c2"]="10:access"
    ["vlan20-c1"]="20:access"
    ["vlan20-c2"]="20:access"
    ["trunk-c1"]="10,20:trunk"
    ["trunk-c2"]="10,20:trunk"
)

# Playground-specific setup function
playground_setup() {
    echo "Setting up VLAN playground..."

    # Configure VLAN access ports for VLAN 10
    for container in vlan10-c1 vlan10-c2; do
        echo "  Configuring $container as VLAN 10 access port"
        set_vlan_tag "$container" "10"
    done

    # Configure VLAN access ports for VLAN 20
    for container in vlan20-c1 vlan20-c2; do
        echo "  Configuring $container as VLAN 20 access port"
        set_vlan_tag "$container" "20"
    done

    # Configure trunk ports
    for container in trunk-c1 trunk-c2; do
        echo "  Configuring $container as trunk port"
        set_trunk_vlans "$container" "10,20"
    done

    echo
    echo "VLAN configuration verification:"
    for container in "${CONTAINERS[@]}"; do
        local vlan_config
        vlan_config=$(get_vlan_config "$container")
        echo "  $container: $vlan_config"
    done

    echo "VLAN configuration complete!"
    return 0
}

# Playground-specific cleanup function
playground_cleanup() {
    echo "Cleaning up VLAN playground..."
    # VLAN settings will be cleaned up when containers are removed
    return 0
}

# Help text for this playground
playground_help() {
    cat << EOF
VLAN Playground Help
===================

This playground demonstrates VLAN segmentation with 6 containers:

VLAN 10 (Access Ports):
  • vlan10-c1 (10.10.0.1/24) - ofport 10
  • vlan10-c2 (10.10.0.2/24) - ofport 11

VLAN 20 (Access Ports):
  • vlan20-c1 (10.20.0.1/24) - ofport 20
  • vlan20-c2 (10.20.0.2/24) - ofport 21

Trunk Ports (carry both VLANs):
  • trunk-c1 (192.168.1.1/24) - ofport 100
  • trunk-c2 (192.168.1.2/24) - ofport 101

Basic usage:
  1. Setup environment: ./lab.sh setup vlan
  2. Test VLAN isolation: ping between same VLAN containers
  3. Verify separation: ping between different VLAN containers should fail
  4. Monitor traffic: tcpdump on trunk ports to see VLAN tags

Expected behavior:
  • vlan10-c1 can reach vlan10-c2 (same VLAN)
  • vlan20-c1 can reach vlan20-c2 (same VLAN)
  • vlan10-c1 CANNOT reach vlan20-c1 (different VLAN)
  • trunk-c1 and trunk-c2 can see all VLANs

Example commands:
  # Test same VLAN connectivity
  ./lab.sh exec vlan10-c1 ping -c 3 10.10.0.2

  # Test VLAN isolation (should fail)
  ./lab.sh exec vlan10-c1 ping -c 3 10.20.0.1

  # Monitor VLAN traffic on trunk (with TTY for better output)
  ./lab.sh exec --tty trunk-c1 tcpdump -i eth0 -n

  # Interactive shell in container
  ./lab.sh exec -it vlan10-c1 bash

  # Show network interfaces with colors
  ./lab.sh exec --tty vlan10-c1 ip -c addr show

  # Check routing table
  ./lab.sh exec vlan20-c1 ip route

  # Interactive network troubleshooting
  ./lab.sh exec -it trunk-c1 /bin/bash

EOF
}
