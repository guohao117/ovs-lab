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
PLAYGROUND_NAME="Simple 3-Container Lab"
PLAYGROUND_DESCRIPTION="Basic setup with 3 containers for testing connectivity and flow rules"
PLAYGROUND_VERSION="1.0"

# Container configuration
CONTAINERS=(c1 c2 c3)

# Network configuration
# Format: ["container_name"]="ip_address/netmask:gateway"
CONTAINER_CONFIG["c1"]="10.0.0.1/24:10.0.0.254"
CONTAINER_CONFIG["c2"]="10.0.0.2/24:10.0.0.254"
CONTAINER_CONFIG["c3"]="20.0.0.1/24:20.0.0.254"

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
    echo "Setting up Simple playground..."
    # Add any playground-specific setup here
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
Simple Playground Help
=====================

This playground creates a basic 3-container environment:
  • c1 (10.0.0.1/24) - ofport 101
  • c2 (10.0.0.2/24) - ofport 102
  • c3 (20.0.0.1/24) - ofport 103

Basic usage:
  1. Setup environment: ./lab.sh setup simple
  2. Test connectivity: ./lab.sh test
  3. Add flows: ./lab.sh flows
  4. Enter containers: ./lab.sh shell c1

Example flow rules using fixed ofports:
  # Forward c1->c2: ovs-ofctl add-flow br-lab "in_port=101,actions=output:102"
  # Forward c2->c3: ovs-ofctl add-flow br-lab "in_port=102,actions=output:103"
  # Forward c3->c1: ovs-ofctl add-flow br-lab "in_port=103,actions=output:101"

EOF
}
