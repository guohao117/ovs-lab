#!/bin/bash
# Example: How to use the new bridge operation helper functions
# This demonstrates safe bridge modifications that automatically handle permissions

# Load the OVS helpers library
source "$(dirname "${BASH_SOURCE[0]}")/lib/ovs-helpers.sh"

echo "=== Example Bridge Operations with Permission Management ==="

# Example 1: Set bridge protocols (safe way)
echo "1. Setting OpenFlow protocols..."
if ovs_bridge_set_protocols "br-lab" "OpenFlow10,OpenFlow13"; then
    echo "   ✓ Protocols set successfully"
else
    echo "   ✗ Failed to set protocols"
fi

# Example 2: Set external ID (safe way)
echo "2. Setting external ID..."
if ovs_bridge_set_external_id "br-lab" "example_key" "example_value"; then
    echo "   ✓ External ID set successfully"
else
    echo "   ✗ Failed to set external ID"
fi

# Example 3: Set multiple properties at once (safe way)
echo "3. Setting multiple properties..."
if ovs_bridge_set_multiple "br-lab" \
    "external_ids:test_key1=value1" \
    "external_ids:test_key2=value2" \
    "fail_mode=secure"; then
    echo "   ✓ Multiple properties set successfully"
else
    echo "   ✗ Failed to set multiple properties"
fi

# Example 4: Verify permissions are maintained
echo "4. Checking bridge management socket permissions..."
mgmt_socket="/usr/local/var/run/openvswitch/br-lab.mgmt"
if [[ -S "$mgmt_socket" ]]; then
    perms=$(ls -la "$mgmt_socket")
    echo "   Socket permissions: $perms"
    if echo "$perms" | grep -q "guohao"; then
        echo "   ✓ Permissions correctly maintained"
    else
        echo "   ✗ Permissions not correctly set"
    fi
else
    echo "   ✗ Management socket not found"
fi

echo "=== Example completed ==="
