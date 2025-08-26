#!/bin/bash

# =============================================================================
# Gateway Flow Validation Script
# =============================================================================
# Validates that OpenFlow rules are correctly configured for 2-layer gateway
# =============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Bridge name
BRIDGE_NAME="${BRIDGE_NAME:-br-lab}"

# Helper functions
print_header() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

print_test() {
    echo -e "${YELLOW}Testing: $1${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_failure() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${BLUE}  $1${NC}"
}

# Check if bridge exists
check_bridge() {
    if ! ovs-vsctl br-exists "$BRIDGE_NAME" 2>/dev/null; then
        echo -e "${RED}Error: Bridge $BRIDGE_NAME does not exist${NC}"
        exit 1
    fi
}

# Validate ARP proxy rules
validate_arp_rules() {
    print_header "Validating ARP Proxy Rules"

    local arp_rules=$(ovs-ofctl dump-flows "$BRIDGE_NAME" | grep "arp,arp_op=1" | wc -l)

    if [[ $arp_rules -ge 6 ]]; then
        print_success "Found $arp_rules ARP proxy rules (expected at least 6)"
    else
        print_failure "Found only $arp_rules ARP proxy rules (expected at least 6)"
        return 1
    fi

    # Check specific ARP rules
    local rules_to_check=(
        "arp_tpa=10.10.0.254"
        "arp_tpa=10.20.0.254"
        "arp_tpa=10.10.0.1"
        "arp_tpa=10.10.0.2"
        "arp_tpa=10.20.0.1"
        "arp_tpa=10.20.0.2"
    )

    local missing_rules=0
    for rule_pattern in "${rules_to_check[@]}"; do
        if ! ovs-ofctl dump-flows "$BRIDGE_NAME" | grep -q "$rule_pattern"; then
            print_failure "Missing ARP rule for: $rule_pattern"
            ((missing_rules++))
        fi
    done

    if [[ $missing_rules -eq 0 ]]; then
        print_success "All required ARP proxy rules are present"
        return 0
    else
        print_failure "Missing $missing_rules ARP proxy rules"
        return 1
    fi
}

# Validate ICMP response rules
validate_icmp_rules() {
    print_header "Validating ICMP Response Rules"

    local icmp_rules=$(ovs-ofctl dump-flows "$BRIDGE_NAME" | grep "icmp,icmp_type=8" | wc -l)

    if [[ $icmp_rules -ge 2 ]]; then
        print_success "Found $icmp_rules ICMP echo reply rules (expected at least 2)"
    else
        print_failure "Found only $icmp_rules ICMP echo reply rules (expected at least 2)"
        return 1
    fi

    # Check specific ICMP rules
    local icmp_checks=(
        "nw_dst=10.10.0.254"
        "nw_dst=10.20.0.254"
    )

    local missing_icmp=0
    for icmp_pattern in "${icmp_checks[@]}"; do
        if ! ovs-ofctl dump-flows "$BRIDGE_NAME" | grep "icmp,icmp_type=8" | grep -q "$icmp_pattern"; then
            print_failure "Missing ICMP echo reply rule for: $icmp_pattern"
            ((missing_icmp++))
        fi
    done

    if [[ $missing_icmp -eq 0 ]]; then
        print_success "All required ICMP echo reply rules are present"
        return 0
    else
        print_failure "Missing $missing_icmp ICMP echo reply rules"
        return 1
    fi
}

# Validate L3 routing rules with dl_dst matching
validate_l3_rules() {
    print_header "Validating L3 Routing Rules"

    # Check that L3 rules include dl_dst matching
    local l3_rules=$(ovs-ofctl dump-flows "$BRIDGE_NAME" | grep "dl_dst=02:ff:00:00:00:fe" | wc -l)

    if [[ $l3_rules -ge 4 ]]; then
        print_success "Found $l3_rules L3 routing rules with dl_dst matching (expected at least 4)"
    else
        print_failure "Found only $l3_rules L3 routing rules with dl_dst matching"
        return 1
    fi

    # Check specific routing directions
    local routing_checks=(
        "nw_src=10.10.0.0/24.*nw_dst=10.20.0.1"
        "nw_src=10.10.0.0/24.*nw_dst=10.20.0.2"
        "nw_src=10.20.0.0/24.*nw_dst=10.10.0.1"
        "nw_src=10.20.0.0/24.*nw_dst=10.10.0.2"
    )

    local missing_routes=0
    for route_pattern in "${routing_checks[@]}"; do
        if ! ovs-ofctl dump-flows "$BRIDGE_NAME" | grep "dl_dst=02:ff:00:00:00:fe" | grep -q "$route_pattern"; then
            print_failure "Missing L3 routing rule for: $route_pattern"
            ((missing_routes++))
        fi
    done

    if [[ $missing_routes -eq 0 ]]; then
        print_success "All required L3 routing rules are present with dl_dst matching"
        return 0
    else
        print_failure "Missing $missing_routes L3 routing rules"
        return 1
    fi
}

# Validate priority ordering
validate_priority_ordering() {
    print_header "Validating Priority Ordering"

    # Check that L3 rules have higher priority than drop rules
    local l3_priority=$(ovs-ofctl dump-flows "$BRIDGE_NAME" | grep "dl_dst=02:ff:00:00:00:fe" | head -1 | grep -o "priority=[0-9]*" | cut -d= -f2)
    local drop_priority=$(ovs-ofctl dump-flows "$BRIDGE_NAME" | grep "nw_dst=10.10.0.254.*actions=drop" | head -1 | grep -o "priority=[0-9]*" | cut -d= -f2)

    if [[ -n "$l3_priority" && -n "$drop_priority" && "$l3_priority" -gt "$drop_priority" ]]; then
        print_success "L3 rules priority ($l3_priority) > drop rules priority ($drop_priority)"
        return 0
    else
        print_failure "Priority ordering incorrect: L3 rules should have higher priority than drop rules"
        return 1
    fi
}

# Validate L2 forwarding rules
validate_l2_rules() {
    print_header "Validating L2 Forwarding Rules"

    local l2_rules=$(ovs-ofctl dump-flows "$BRIDGE_NAME" | grep -E "dl_dst=02:(10|20):00:00:00:0[12]" | wc -l)

    if [[ $l2_rules -eq 4 ]]; then
        print_success "Found $l2_rules L2 forwarding rules (expected 4)"
        return 0
    else
        print_failure "Found $l2_rules L2 forwarding rules (expected 4)"
        return 1
    fi
}

# Validate security rules
validate_security_rules() {
    print_header "Validating Security Rules"

    # Check cross-subnet drop rules
    local drop_rules=$(ovs-ofctl dump-flows "$BRIDGE_NAME" | grep -E "dl_src=02:(10|20):00:00:00:00/ff:ff:00:00:00:00.*dl_dst=02:(10|20):00:00:00:00/ff:ff:00:00:00:00" | wc -l)

    if [[ $drop_rules -ge 2 ]]; then
        print_success "Found $drop_rules cross-subnet security drop rules"
        return 0
    else
        print_failure "Found only $drop_rules cross-subnet security drop rules"
        return 1
    fi
}

# Main validation function
main() {
    print_header "Gateway Flow Rules Validation"
    echo -e "Validating OpenFlow rules on bridge: ${BLUE}$BRIDGE_NAME${NC}"

    check_bridge

    local tests_passed=0
    local tests_failed=0

    # Run all validation tests
    if validate_arp_rules; then ((tests_passed++)); else ((tests_failed++)); fi
    if validate_icmp_rules; then ((tests_passed++)); else ((tests_failed++)); fi
    if validate_l3_rules; then ((tests_passed++)); else ((tests_failed++)); fi
    if validate_priority_ordering; then ((tests_passed++)); else ((tests_failed++)); fi
    if validate_l2_rules; then ((tests_passed++)); else ((tests_failed++)); fi
    if validate_security_rules; then ((tests_passed++)); else ((tests_failed++)); fi

    # Print summary
    print_header "Validation Summary"
    echo -e "Tests passed: ${GREEN}$tests_passed${NC}"
    echo -e "Tests failed: ${RED}$tests_failed${NC}"

    if [[ $tests_failed -eq 0 ]]; then
        echo -e "\n${GREEN}🎉 All flow rule validations passed! Gateway is correctly configured.${NC}"
        exit 0
    else
        echo -e "\n${RED}❌ Some validations failed. Please check the OpenFlow rules.${NC}"
        exit 1
    fi
}

# Handle command line arguments
case "${1:-}" in
    "help")
        echo "Usage: $0 [help]"
        echo "  help - Show this help message"
        echo ""
        echo "Validates OpenFlow rules for 2-layer gateway functionality"
        echo "Checks: ARP proxy, ICMP response, L3 routing with dl_dst matching, priority ordering, L2 forwarding, security"
        ;;
    *)
        main
        ;;
esac
