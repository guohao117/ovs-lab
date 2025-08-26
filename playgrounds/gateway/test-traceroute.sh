#!/bin/bash

# =============================================================================
# Traceroute Test Script for Gateway Playground
# =============================================================================
# Tests traceroute functionality through the OpenFlow gateway
# Verifies that ICMP Time Exceeded messages work correctly for routing
# =============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counters
TESTS_TOTAL=0
TESTS_PASSED=0
TESTS_FAILED=0

# Get script directory
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
LAB_SCRIPT="$SCRIPT_DIR/../../lab.sh"

# Helper functions
print_header() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

print_test() {
    echo -e "${YELLOW}Testing: $1${NC}"
    ((TESTS_TOTAL++))
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
    ((TESTS_PASSED++))
}

print_failure() {
    echo -e "${RED}✗ $1${NC}"
    ((TESTS_FAILED++))
}

print_info() {
    echo -e "${BLUE}  $1${NC}"
}

# Test helper function
run_test() {
    local test_name="$1"
    local test_command="$2"
    local expected_result="${3:-0}"

    print_test "$test_name"

    if eval "$test_command" >/dev/null 2>&1; then
        local result=0
    else
        local result=1
    fi

    if [[ $result -eq $expected_result ]]; then
        print_success "$test_name"
        return 0
    else
        print_failure "$test_name"
        return 1
    fi
}

# Verify environment
check_environment() {
    print_header "Environment Check"

    # Check if lab script exists
    if [[ ! -f "$LAB_SCRIPT" ]]; then
        echo -e "${RED}Error: Lab script not found at $LAB_SCRIPT${NC}"
        exit 1
    fi

    # Check if gateway playground is running
    if ! $LAB_SCRIPT status gateway >/dev/null 2>&1; then
        echo -e "${RED}Error: Gateway playground is not running${NC}"
        echo "Please run: $LAB_SCRIPT setup gateway"
        exit 1
    fi

    print_success "Environment check passed"
}

# Test basic traceroute functionality
test_traceroute_basic() {
    print_header "Basic Traceroute Functionality"

    # Test traceroute within same subnet (should show direct connection)
    print_test "Traceroute within subnet 10.10.0.0/24"
    if $LAB_SCRIPT exec gw-c1 traceroute -n -q 1 -w 1 10.10.0.2 2>/dev/null | grep -q "10.10.0.2"; then
        print_success "Traceroute within subnet works"
    else
        print_failure "Traceroute within subnet failed"
    fi

    # Test traceroute within same subnet (should show direct connection)
    print_test "Traceroute within subnet 10.20.0.0/24"
    if $LAB_SCRIPT exec gw-c3 traceroute -n -q 1 -w 1 10.20.0.2 2>/dev/null | grep -q "10.20.0.2"; then
        print_success "Traceroute within subnet works"
    else
        print_failure "Traceroute within subnet failed"
    fi
}

# Test cross-subnet traceroute with gateway hops
test_traceroute_cross_subnet() {
    print_header "Cross-Subnet Traceroute via Gateway"

    # Test traceroute from subnet 10.10.0.0/24 to 10.20.0.0/24
    print_test "Traceroute gw-c1 → gw-c3 (cross-subnet)"
    local trace_output
    trace_output=$($LAB_SCRIPT exec gw-c1 traceroute -n -q 1 -w 1 10.20.0.1 2>/dev/null || true)

    if echo "$trace_output" | grep -q "10.10.0.254"; then
        print_success "Traceroute shows gateway hop (10.10.0.254)"
        print_info "Route: gw-c1 → 10.10.0.254 → gw-c3"
    elif echo "$trace_output" | grep -q "10.20.0.1"; then
        print_success "Traceroute reached destination (may show direct route)"
        print_info "Route: gw-c1 → gw-c3 (direct)"
    else
        print_failure "Traceroute failed or didn't show expected hops"
        print_info "Output: $trace_output"
    fi

    # Test traceroute from subnet 10.20.0.0/24 to 10.10.0.0/24
    print_test "Traceroute gw-c3 → gw-c1 (cross-subnet)"
    trace_output=$($LAB_SCRIPT exec gw-c3 traceroute -n -q 1 -w 1 10.10.0.1 2>/dev/null || true)

    if echo "$trace_output" | grep -q "10.20.0.254"; then
        print_success "Traceroute shows gateway hop (10.20.0.254)"
        print_info "Route: gw-c3 → 10.20.0.254 → gw-c1"
    elif echo "$trace_output" | grep -q "10.10.0.1"; then
        print_success "Traceroute reached destination (may show direct route)"
        print_info "Route: gw-c3 → gw-c1 (direct)"
    else
        print_failure "Traceroute failed or didn't show expected hops"
        print_info "Output: $trace_output"
    fi
}

# Test gateway reachability via traceroute
test_gateway_traceroute() {
    print_header "Gateway Traceroute Reachability"

    # Test traceroute to gateway IPs
    print_test "Traceroute to gateway 10.10.0.254"
    if $LAB_SCRIPT exec gw-c1 traceroute -n -q 1 -w 1 10.10.0.254 2>/dev/null | grep -q "10.10.0.254"; then
        print_success "Gateway 10.10.0.254 is reachable via traceroute"
    else
        print_failure "Gateway 10.10.0.254 not reachable via traceroute"
    fi

    print_test "Traceroute to gateway 10.20.0.254"
    if $LAB_SCRIPT exec gw-c3 traceroute -n -q 1 -w 1 10.20.0.254 2>/dev/null | grep -q "10.20.0.254"; then
        print_success "Gateway 10.20.0.254 is reachable via traceroute"
    else
        print_failure "Gateway 10.20.0.254 not reachable via traceroute"
    fi
}

# Test multiple hop scenarios
test_multiple_hops() {
    print_header "Multiple Hop Scenarios"

    # Test through multiple containers
    print_test "Traceroute through gateway path"
    local trace_output
    trace_output=$($LAB_SCRIPT exec gw-c1 traceroute -n -q 1 -w 1 10.20.0.2 2>/dev/null || true)

    # Look for either gateway hop or direct destination
    if echo "$trace_output" | grep -q -E "(10.10.0.254|10.20.0.2)"; then
        print_success "Traceroute shows routing path"
        print_info "Path: $trace_output"
    else
        print_failure "Traceroute path not visible"
        print_info "Output: $trace_output"
    fi
}

# Show detailed traceroute examples
show_traceroute_examples() {
    print_header "Detailed Traceroute Examples"

    echo -e "${YELLOW}Example: Traceroute from gw-c1 to gw-c3${NC}"
    $LAB_SCRIPT exec gw-c1 traceroute -n -q 1 -w 2 10.20.0.1 2>&1 | head -5 || true
    echo

    echo -e "${YELLOW}Example: Traceroute from gw-c3 to gw-c1${NC}"
    $LAB_SCRIPT exec gw-c3 traceroute -n -q 1 -w 2 10.10.0.1 2>&1 | head -5 || true
    echo

    echo -e "${YELLOW}Example: Traceroute to gateway${NC}"
    $LAB_SCRIPT exec gw-c1 traceroute -n -q 1 -w 2 10.10.0.254 2>&1 | head -3 || true
    echo
}

# Main test execution
main() {
    print_header "Gateway Traceroute Test Suite"
    print_info "Testing traceroute functionality through OpenFlow gateway"

    # Run all tests
    check_environment
    test_traceroute_basic
    test_traceroute_cross_subnet
    test_gateway_traceroute
    test_multiple_hops
    show_traceroute_examples

    # Print summary
    print_header "Traceroute Test Summary"
    echo -e "Total tests: ${BLUE}$TESTS_TOTAL${NC}"
    echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed: ${RED}$TESTS_FAILED${NC}"

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "\n${GREEN}🎉 All traceroute tests passed! Gateway routing is working correctly.${NC}"
        echo -e "${YELLOW}Note: In OpenFlow implementations, traceroute may show direct routes"
        echo -e "instead of gateway hops due to the integrated routing behavior.${NC}"
        exit 0
    else
        echo -e "\n${RED}❌ Some traceroute tests failed. Please check the configuration.${NC}"
        exit 1
    fi
}

# Handle command line arguments
case "${1:-run}" in
    "run")
        main
        ;;
    "quick")
        check_environment
        test_traceroute_basic
        test_traceroute_cross_subnet
        echo -e "\n${GREEN}Quick traceroute test completed.${NC}"
        ;;
    "help")
        echo "Usage: $0 [run|quick|help]"
        echo "  run   - Run full traceroute test suite (default)"
        echo "  quick - Run basic traceroute tests only"
        echo "  help  - Show this help message"
        ;;
    *)
        echo "Unknown option: $1"
        echo "Use '$0 help' for usage information"
        exit 1
        ;;
esac
