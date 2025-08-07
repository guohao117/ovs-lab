#!/bin/bash

# =============================================================================
# OVS Lab Helper Functions Library
# =============================================================================
# Common utility functions for low-level OVS operations
# =============================================================================

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
