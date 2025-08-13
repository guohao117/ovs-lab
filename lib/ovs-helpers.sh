#!/bin/bash

# =============================================================================
# OVS Lab Helper Functions Library
# =============================================================================
# Common utility functions for low-level OVS operations
# =============================================================================

# Setup bridge management socket permissions (internal helper)
_setup_bridge_permissions() {
    local bridge_name="${1:-br-lab}"
    local mgmt_sock="/usr/local/var/run/openvswitch/${bridge_name}.mgmt"
    local max_wait=5
    local wait_count=0
    local real_user="${SUDO_USER:-$USER}"

    # Wait for management socket to be created
    while [[ ! -S "$mgmt_sock" && $wait_count -lt $max_wait ]]; do
        sleep 0.5
        ((wait_count++))
    done

    if [[ -S "$mgmt_sock" ]]; then
        sudo chown :"$real_user" "$mgmt_sock" && sudo chmod g+rw "$mgmt_sock" 2>/dev/null || true
    fi
}

# Safe bridge configuration function - automatically handles permissions
# Usage: ovs_bridge_set <bridge_name> <key> <value>
ovs_bridge_set() {
    local bridge_name="$1"
    local key="$2"
    local value="$3"
    
    if [[ -z "$bridge_name" || -z "$key" || -z "$value" ]]; then
        echo "Error: Usage: ovs_bridge_set <bridge_name> <key> <value>" >&2
        return 1
    fi
    
    # Execute the bridge modification
    local result=0
    ovs-vsctl set bridge "$bridge_name" "$key=$value" &>/dev/null || result=$?
    
    # Re-setup permissions after any bridge modification
    _setup_bridge_permissions "$bridge_name"
    
    return $result
}

# Safe bridge external_ids set function
# Usage: ovs_bridge_set_external_id <bridge_name> <key> <value>
ovs_bridge_set_external_id() {
    local bridge_name="$1"
    local key="$2"
    local value="$3"
    
    if [[ -z "$bridge_name" || -z "$key" || -z "$value" ]]; then
        echo "Error: Usage: ovs_bridge_set_external_id <bridge_name> <key> <value>" >&2
        return 1
    fi
    
    # Execute the bridge modification
    local result=0
    ovs-vsctl set bridge "$bridge_name" "external_ids:$key=$value" &>/dev/null || result=$?
    
    # Re-setup permissions after any bridge modification
    _setup_bridge_permissions "$bridge_name"
    
    return $result
}

# Safe bridge protocols set function
# Usage: ovs_bridge_set_protocols <bridge_name> <protocols>
# Example: ovs_bridge_set_protocols br-lab "OpenFlow10,OpenFlow13"
ovs_bridge_set_protocols() {
    local bridge_name="$1"
    local protocols="$2"
    
    if [[ -z "$bridge_name" || -z "$protocols" ]]; then
        echo "Error: Usage: ovs_bridge_set_protocols <bridge_name> <protocols>" >&2
        return 1
    fi
    
    # Execute the bridge modification
    local result=0
    ovs-vsctl set bridge "$bridge_name" "protocols=$protocols" &>/dev/null || result=$?
    
    # Re-setup permissions after any bridge modification
    _setup_bridge_permissions "$bridge_name"
    
    return $result
}

# Safe bridge multiple properties set function
# Usage: ovs_bridge_set_multiple <bridge_name> <key1=value1> <key2=value2> ...
ovs_bridge_set_multiple() {
    local bridge_name="$1"
    shift
    
    if [[ -z "$bridge_name" || $# -eq 0 ]]; then
        echo "Error: Usage: ovs_bridge_set_multiple <bridge_name> <key1=value1> ..." >&2
        return 1
    fi
    
    # Execute the bridge modification
    local result=0
    ovs-vsctl set bridge "$bridge_name" "$@" &>/dev/null || result=$?
    
    # Re-setup permissions after any bridge modification
    _setup_bridge_permissions "$bridge_name"
    
    return $result
}

# Get the actual OVS port name for a container
# Usage: get_port_name <container_name>
get_port_name() {
    local container="$1"
    if [[ -z "$container" ]]; then
        echo "Error: Container name required" >&2
        return 1
    fi
    
    ovs-vsctl --data=bare --no-heading --columns=name find Interface \
        external_ids:container_id="$container" external_ids:container_iface=eth0 2>/dev/null
}

# Get the ofport number for a container
# Usage: get_container_ofport <container_name>
get_container_ofport() {
    local container="$1"
    if [[ -z "$container" ]]; then
        echo "Error: Container name required" >&2
        return 1
    fi
    
    ovs-vsctl --data=bare --no-heading --columns=ofport find Interface \
        external_ids:container_id="$container" external_ids:container_iface=eth0 2>/dev/null
}

# Set VLAN tag for a container port
# Usage: set_vlan_tag <container_name> <vlan_id>
set_vlan_tag() {
    local container="$1"
    local vlan_id="$2"
    
    if [[ -z "$container" || -z "$vlan_id" ]]; then
        echo "Error: Container name and VLAN ID required" >&2
        return 1
    fi
    
    local port_name
    port_name=$(get_port_name "$container")
    
    if [[ -z "$port_name" ]]; then
        echo "Error: Could not find port for container $container" >&2
        return 1
    fi
    
    if ovs-vsctl set port "$port_name" tag="$vlan_id"; then
        echo "✓ Set VLAN tag $vlan_id for $container ($port_name)"
        return 0
    else
        echo "✗ Failed to set VLAN tag $vlan_id for $container ($port_name)" >&2
        return 1
    fi
}

# Set trunk configuration for a container port
# Usage: set_trunk_vlans <container_name> <vlan_list>
# Example: set_trunk_vlans trunk-c1 "10,20"
set_trunk_vlans() {
    local container="$1"
    local vlan_list="$2"
    
    if [[ -z "$container" || -z "$vlan_list" ]]; then
        echo "Error: Container name and VLAN list required" >&2
        return 1
    fi
    
    local port_name
    port_name=$(get_port_name "$container")
    
    if [[ -z "$port_name" ]]; then
        echo "Error: Could not find port for container $container" >&2
        return 1
    fi
    
    if ovs-vsctl set port "$port_name" trunks="$vlan_list"; then
        echo "✓ Set trunk VLANs [$vlan_list] for $container ($port_name)"
        return 0
    else
        echo "✗ Failed to set trunk VLANs [$vlan_list] for $container ($port_name)" >&2
        return 1
    fi
}

# Clear VLAN configuration for a container port
# Usage: clear_vlan_config <container_name>
clear_vlan_config() {
    local container="$1"
    
    if [[ -z "$container" ]]; then
        echo "Error: Container name required" >&2
        return 1
    fi
    
    local port_name
    port_name=$(get_port_name "$container")
    
    if [[ -z "$port_name" ]]; then
        echo "Warning: Could not find port for container $container" >&2
        return 1
    fi
    
    # Clear both tag and trunks
    ovs-vsctl clear port "$port_name" tag 2>/dev/null || true
    ovs-vsctl clear port "$port_name" trunks 2>/dev/null || true
    
    echo "✓ Cleared VLAN configuration for $container ($port_name)"
    return 0
}

# Get VLAN configuration for a container
# Usage: get_vlan_config <container_name>
get_vlan_config() {
    local container="$1"
    
    if [[ -z "$container" ]]; then
        echo "Error: Container name required" >&2
        return 1
    fi
    
    local port_name
    port_name=$(get_port_name "$container")
    
    if [[ -z "$port_name" ]]; then
        echo "Error: Could not find port for container $container" >&2
        return 1
    fi
    
    local tag trunks
    tag=$(ovs-vsctl --data=bare --no-heading get port "$port_name" tag 2>/dev/null || echo "[]")
    trunks=$(ovs-vsctl --data=bare --no-heading get port "$port_name" trunks 2>/dev/null || echo "[]")
    
    if [[ "$tag" != "[]" ]]; then
        echo "access vlan $tag"
    elif [[ "$trunks" != "[]" ]]; then
        echo "trunk vlans $trunks"
    else
        echo "no vlan config"
    fi
}
