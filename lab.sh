#!/bin/bash
set -euo pipefail

# =============================================================================
# OVS Lab Manager - Enhanced Version
# =============================================================================
# A comprehensive script for managing OpenVSwitch laboratory environments
# with Docker containers for network testing and experimentation.
# =============================================================================

# Global Configuration
readonly SCRIPT_NAME="OVS Lab Manager"
readonly BRIDGE_NAME_DEFAULT="br-lab"
readonly LOG_LEVEL=${LOG_LEVEL:-"INFO"}
readonly PLAYGROUND_DIR="$(dirname "$0")/playgrounds"

# Get real user (even when running with sudo)
readonly REAL_USER="${SUDO_USER:-$USER}"

# Default configuration (will be overridden by playground)
BRIDGE_NAME="$BRIDGE_NAME_DEFAULT"
CONTAINERS=()
declare -A CONTAINER_CONFIG=()
declare -A CONTAINER_OFPORT=()

# Set default configuration if no playground is loaded
set_default_config() {
    if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
        CONTAINERS=(c1 c2 c3)
        CONTAINER_CONFIG=(
            ["c1"]="10.0.0.1/24:10.0.0.254"
            ["c2"]="10.0.0.2/24:10.0.0.254"
            ["c3"]="20.0.0.1/24:20.0.0.254"
        )
        CONTAINER_OFPORT=(
            ["c1"]="101"
            ["c2"]="102"
            ["c3"]="103"
        )
    fi
}

# Playground configuration
CURRENT_PLAYGROUND=""
PLAYGROUND_NAME=""
PLAYGROUND_DESCRIPTION=""
PLAYGROUND_VERSION=""

# Color codes for output
readonly RED=$'\033[0;31m'
readonly GREEN=$'\033[0;32m'
readonly YELLOW=$'\033[1;33m'
readonly BLUE=$'\033[0;34m'
readonly MAGENTA=$'\033[0;35m'
readonly CYAN=$'\033[0;36m'
readonly NC=$'\033[0m'  # No Color

# =============================================================================
# Utility Functions
# =============================================================================

# Logging function with levels
log() {
    local level="$1"
    shift
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    case "$level" in
        ERROR)   echo -e "${RED}[ERROR]${NC} $*" >&2 ;;
        WARN)    echo -e "${YELLOW}[WARN]${NC} $*" >&2 ;;
        INFO)    echo -e "${GREEN}[INFO]${NC} $*" ;;
        DEBUG)   [[ "$LOG_LEVEL" == "DEBUG" ]] && echo -e "${BLUE}[DEBUG]${NC} $*" ;;
        SUCCESS) echo -e "${GREEN}✓${NC} $*" ;;
        *)       echo "$*" ;;
    esac
}

# Enhanced error handling
die() {
    log ERROR "$*"
    exit 1
}

# Progress indicator
progress() {
    local msg="$1"
    echo -ne "${CYAN}${msg}...${NC}"
}

progress_done() {
    echo -e " ${GREEN}✓${NC}"
}

progress_fail() {
    echo -e " ${RED}✗${NC}"
}

# =============================================================================
# Validation Functions
# =============================================================================

# Check if user has docker access
check_docker_access() {
    if docker ps &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Check if permissions are properly set up for non-setup operations
check_permissions() {
    local ovs_sock="/usr/local/var/run/openvswitch/db.sock"

    if ! check_docker_access; then
        log ERROR "Docker access required. Add user to docker group if needed"
        return 1
    fi

    if ! ovs-vsctl show &>/dev/null; then
        log ERROR "OVS access not configured for user $REAL_USER. Please run setup first"
        log INFO "Run: $0 setup"
        return 1
    fi

    return 0
}

# Check required commands
check_dependencies() {
    local missing_deps=()
    local required_commands=(docker ovs-vsctl ovs-ofctl ovs-docker)

    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log ERROR "Missing required dependencies:"
        printf '%s\n' "${missing_deps[@]}" | sed 's/^/  - /'
        die "Please install missing dependencies and try again."
    fi

    log SUCCESS "All dependencies satisfied"
}

# Validate container name
validate_container() {
    local container="$1"
    if [[ ! " ${CONTAINERS[*]} " =~ " $container " ]]; then
        log ERROR "Invalid container name: $container"
        log INFO "Available containers: ${CONTAINERS[*]}"
        return 1
    fi
    return 0
}

# Check if container is running
is_container_running() {
    local container="$1"
    docker ps --format '{{.Names}}' | grep -q "^${container}$"
}

# Check if bridge exists
bridge_exists() {
    ovs-vsctl br-exists "$BRIDGE_NAME" 2>/dev/null
}

# =============================================================================
# OVS Permission Setup Functions
# =============================================================================

# Setup OVS permissions for current user
setup_ovs_permissions() {
    log INFO "Setting up OVS permissions for user $REAL_USER..."

    local ovs_sock="/usr/local/var/run/openvswitch/db.sock"
    local mgmt_sock="/usr/local/var/run/openvswitch/br-lab.mgmt"

    if [[ -S "$ovs_sock" ]]; then
        progress "Setting permissions for OVS database socket"
        if sudo chown :$REAL_USER "$ovs_sock" && sudo chmod g+rw "$ovs_sock"; then
            progress_done
            log SUCCESS "OVS database socket permissions set"
        else
            progress_fail
            log WARN "Failed to set OVS database socket permissions"
        fi
    else
        log WARN "OVS database socket not found at $ovs_sock"
    fi

    # The mgmt socket will be created when bridge is created, so we'll handle it later
}

# Setup bridge management socket permissions (called after bridge creation)
setup_bridge_permissions() {
    local mgmt_sock="/usr/local/var/run/openvswitch/br-lab.mgmt"

    if [[ -S "$mgmt_sock" ]]; then
        progress "Setting permissions for bridge management socket"
        if sudo chown :$REAL_USER "$mgmt_sock" && sudo chmod g+rw "$mgmt_sock"; then
            progress_done
            log SUCCESS "Bridge management socket permissions set"
        else
            progress_fail
            log WARN "Failed to set bridge management socket permissions"
        fi
    fi
}

# =============================================================================
# Core Lab Management Functions
# =============================================================================

# Set fixed ofport for a container's interface
set_container_ofport() {
    local container="$1"
    local desired_ofport="${CONTAINER_OFPORT[$container]:-}"

    if [[ -z "$desired_ofport" ]]; then
        log WARN "No ofport mapping defined for container $container"
        return 0
    fi

    # Find the interface name for this container
    local interface_name
    interface_name=$(ovs-vsctl --data=bare --no-heading --columns=name find Interface \
        external_ids:container_id="$container" external_ids:container_iface=eth0 2>/dev/null)

    if [[ -z "$interface_name" ]]; then
        log ERROR "Failed to find interface for container $container"
        return 1
    fi

    # Set the ofport_request
    progress "Setting ofport $desired_ofport for $container"
    if ovs-vsctl set Interface "$interface_name" ofport_request="$desired_ofport" &>/dev/null; then
        progress_done

        # Verify the ofport was actually assigned
        local actual_ofport
        actual_ofport=$(ovs-vsctl --data=bare --no-heading --columns=ofport find Interface name="$interface_name" 2>/dev/null)

        if [[ "$actual_ofport" == "$desired_ofport" ]]; then
            log SUCCESS "Container $container verified at ofport $desired_ofport"
        else
            log WARN "Container $container ofport mismatch: requested $desired_ofport, got $actual_ofport"
        fi
    else
        progress_fail
        log ERROR "Failed to set ofport for container $container"
        return 1
    fi
}

# =============================================================================
# Playground Management Functions
# =============================================================================

# Set playground information in bridge external_ids
set_playground_state() {
    local playground="$1"
    if bridge_exists; then
        ovs-vsctl set bridge "$BRIDGE_NAME" external_ids:playground="$playground" &>/dev/null
        log SUCCESS "Playground state saved: $playground"
    fi
}

# Get current playground from bridge external_ids
get_current_playground() {
    if bridge_exists; then
        ovs-vsctl --data=bare --no-heading get bridge "$BRIDGE_NAME" external_ids:playground 2>/dev/null | tr -d '"'
    fi
}

# Auto-load current playground configuration
auto_load_current_playground() {
    local current_pg
    current_pg=$(get_current_playground)

    if [[ -n "$current_pg" && "$current_pg" != "[]" ]]; then
        log INFO "Detected active playground: $current_pg"
        if load_playground "$current_pg"; then
            return 0
        else
            log WARN "Failed to load detected playground: $current_pg"
            return 1
        fi
    else
        log INFO "No active playground detected, using default configuration"
        set_default_config
        return 0
    fi
}

# List available playgrounds
list_playgrounds() {
    echo -e "${CYAN}Available Playgrounds:${NC}"

    if [[ ! -d "$PLAYGROUND_DIR" ]]; then
        echo -e "${YELLOW}No playgrounds directory found${NC}"
        return 1
    fi

    local found=false
    for playground_path in "$PLAYGROUND_DIR"/*; do
        if [[ -d "$playground_path" && -f "$playground_path/config.sh" ]]; then
            local playground_name=$(basename "$playground_path")

            # Source the config to get metadata
            local temp_name temp_desc temp_version
            (
                source "$playground_path/config.sh" 2>/dev/null
                echo "${playground_name}|${PLAYGROUND_NAME:-$playground_name}|${PLAYGROUND_DESCRIPTION:-No description}"
            ) | while IFS='|' read -r pg_name pg_title pg_desc; do
                echo -e "  ${GREEN}$pg_name${NC}: $pg_title"
                echo -e "    $pg_desc"
            done
            found=true
        fi
    done

    if [[ "$found" != true ]]; then
        echo -e "${YELLOW}No valid playgrounds found${NC}"
        return 1
    fi
}

# Load playground configuration
load_playground() {
    local playground="$1"

    if [[ -z "$playground" ]]; then
        log INFO "Using default configuration (no playground specified)"
        return 0
    fi

    local playground_path="$PLAYGROUND_DIR/$playground"
    local config_file="$playground_path/config.sh"

    if [[ ! -f "$config_file" ]]; then
        log ERROR "Playground '$playground' not found: $config_file"
        return 1
    fi

    log INFO "Loading playground: $playground"

    # Source the playground configuration
    if source "$config_file"; then
        CURRENT_PLAYGROUND="$playground"
        log SUCCESS "Playground '$playground' loaded: ${PLAYGROUND_NAME:-$playground}"

        # Override bridge name if specified in playground
        if [[ -n "${BRIDGE_NAME:-}" ]]; then
            log INFO "Using bridge: $BRIDGE_NAME"
        else
            BRIDGE_NAME="$BRIDGE_NAME_DEFAULT"
        fi

        return 0
    else
        log ERROR "Failed to load playground configuration: $config_file"
        return 1
    fi
}

# Call playground-specific setup function if it exists
playground_setup_hook() {
    if declare -f playground_setup >/dev/null 2>&1; then
        log INFO "Running playground-specific setup..."
        if playground_setup; then
            log SUCCESS "Playground setup completed"
        else
            log WARN "Playground setup had issues"
        fi
    fi
}

# Call playground-specific cleanup function if it exists
playground_cleanup_hook() {
    if declare -f playground_cleanup >/dev/null 2>&1; then
        log INFO "Running playground-specific cleanup..."
        playground_cleanup
    fi
}

# Show playground help
show_playground_help() {
    local playground="${1:-$CURRENT_PLAYGROUND}"

    if [[ -z "$playground" ]]; then
        echo -e "${YELLOW}No playground loaded${NC}"
        return 1
    fi

    local playground_path="$PLAYGROUND_DIR/$playground"
    local config_file="$playground_path/config.sh"

    if [[ ! -f "$config_file" ]]; then
        log ERROR "Playground '$playground' not found"
        return 1
    fi

    # Source the config and call help function
    (
        source "$config_file"
        if declare -f playground_help >/dev/null 2>&1; then
            playground_help
        else
            echo "No help available for playground: $playground"
        fi
    )
}

# Create and configure a single container
create_container() {
    local container="$1"
    local config="${CONTAINER_CONFIG[$container]:-}"

    if [[ -z "$config" ]]; then
        log ERROR "No configuration found for container: $container"

        return 1
    fi

    local ip_cidr="${config%:*}"
    local gateway="${config#*:}"

    progress "Creating container $container"

    # Remove existing container if it exists
    docker rm -f "$container" &>/dev/null || true

    # Create new container
    if docker run -d --name "$container" --network none --privileged \
        nicolaka/netshoot:latest sleep infinity &>/dev/null; then
        progress_done
    else
        progress_fail
        die "Failed to create container $container"
    fi

    # Connect to bridge with network configuration
    progress "Connecting $container to bridge"
    if sudo ovs-docker add-port "$BRIDGE_NAME" eth0 "$container" \
        --ipaddress="$ip_cidr" --gateway="$gateway" &>/dev/null; then
        progress_done
        log SUCCESS "Container $container configured with IP $ip_cidr, GW $gateway"

        # Set fixed ofport for consistent OpenFlow port numbering
        set_container_ofport "$container"
    else
        progress_fail
        die "Failed to connect container $container to bridge"
    fi
}

# Setup complete lab environment
setup_lab() {
    log INFO "Setting up OVS lab environment..."

    # Ensure we have configuration loaded
    set_default_config

    # First, setup OVS permissions
    setup_ovs_permissions

    # Cleanup existing environment
    cleanup_containers

    # Create bridge if it doesn't exist
    if ! bridge_exists; then
        progress "Creating OVS bridge $BRIDGE_NAME"
        if ovs-vsctl add-br "$BRIDGE_NAME" &>/dev/null; then
            progress_done
            # Setup bridge socket permissions after creation
            setup_bridge_permissions
        else
            progress_fail
            die "Failed to create bridge $BRIDGE_NAME"
        fi
    else
        log INFO "Bridge $BRIDGE_NAME already exists"
        # Still try to setup permissions for existing bridge
        setup_bridge_permissions
    fi

    # Clear existing flows
    flush_flows

    # Create containers in sequence for consistent port numbering
    for container in "${CONTAINERS[@]}"; do
        create_container "$container"
    done

    # Run playground-specific setup if available
    playground_setup_hook

    # Save playground state to bridge
    if [[ -n "$CURRENT_PLAYGROUND" ]]; then
        set_playground_state "$CURRENT_PLAYGROUND"
    else
        set_playground_state "default"
    fi

    log SUCCESS "OVS lab setup complete!"
    if [[ -n "$CURRENT_PLAYGROUND" ]]; then
        log INFO "Playground: $CURRENT_PLAYGROUND ($PLAYGROUND_NAME)"
    fi
    log INFO "You can now run lab commands without sudo"
    show_lab_status
}

# Cleanup containers and their connections
cleanup_containers() {
    log INFO "Cleaning up existing containers..."

    # Run playground-specific cleanup first
    playground_cleanup_hook

    for container in "${CONTAINERS[@]}"; do
        # Remove port from bridge if it exists
        sudo ovs-docker del-port "$BRIDGE_NAME" eth0 "$container" &>/dev/null || true

        # Remove container
        if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
            progress "Removing container $container"
            if docker rm -f "$container" &>/dev/null; then
                progress_done
            else
                progress_fail
                log WARN "Failed to remove container $container"
            fi
        fi
    done
}

# Destroy entire lab environment
destroy_lab() {
    echo -e "${YELLOW}WARNING: This will destroy the entire lab environment!${NC}"
    read -rp "Are you sure? Type 'yes' to confirm: " confirm

    if [[ "$confirm" != "yes" ]]; then
        log INFO "Lab destruction cancelled"
        return 0
    fi

    log INFO "Destroying lab environment..."

    # Flush flows
    flush_flows

    # Cleanup containers
    cleanup_containers

    # Optionally remove bridge
    read -rp "Remove bridge $BRIDGE_NAME? [y/N]: " remove_bridge
    if [[ "$remove_bridge" =~ ^[Yy]$ ]]; then
        if bridge_exists; then
            progress "Removing bridge $BRIDGE_NAME"
            if ovs-vsctl del-br "$BRIDGE_NAME" &>/dev/null; then
                progress_done
            else
                progress_fail
                log WARN "Failed to remove bridge $BRIDGE_NAME"
            fi
        fi
    fi

    log SUCCESS "Lab environment destroyed"
    exit 0
}

# =============================================================================
# Flow Management Functions
# =============================================================================

# Flush all flows from bridge
flush_flows() {
    if bridge_exists; then
        progress "Flushing flows on $BRIDGE_NAME"
        if ovs-ofctl --strict del-flows "$BRIDGE_NAME" &>/dev/null; then
            progress_done
        else
            progress_fail
            log WARN "Failed to flush flows"
        fi
    else
        log WARN "Bridge $BRIDGE_NAME does not exist"
    fi
}

# Display current flows
# Show current flows on the bridge
show_flows() {
    # Auto-load current playground configuration to get correct bridge name
    auto_load_current_playground

    if ! bridge_exists; then
        log ERROR "Bridge $BRIDGE_NAME does not exist"
        return 1
    fi

    echo -e "${CYAN}Current flows on $BRIDGE_NAME:${NC}"
    ovs-ofctl dump-flows "$BRIDGE_NAME" || log ERROR "Failed to dump flows"
}

# Add a simple learning switch flow
# Add learning switch flows to bridge
add_learning_flows() {
    if ! bridge_exists; then
        log ERROR "Bridge $BRIDGE_NAME does not exist"
        return 1
    fi

    progress "Adding learning switch flows"
    if ovs-ofctl add-flow "$BRIDGE_NAME" "table=0, priority=0, actions=flood" &>/dev/null; then
        progress_done
        log SUCCESS "Learning switch flows added"
    else
        progress_fail
        log ERROR "Failed to add learning switch flows"
        return 1
    fi
}

# Add example flows demonstrating fixed ofport usage
add_example_flows() {
    if ! bridge_exists; then
        log ERROR "Bridge $BRIDGE_NAME does not exist"
        return 1
    fi

    echo -e "\n${CYAN}Adding example flows using fixed ofports...${NC}"

    # Clear existing flows first
    progress "Clearing existing flows"
    if ovs-ofctl del-flows "$BRIDGE_NAME" &>/dev/null; then
        progress_done
    else
        progress_fail
        log ERROR "Failed to clear flows"
        return 1
    fi

    # Add specific forwarding rules using fixed ofports
    echo -e "${GREEN}Adding targeted forwarding rules:${NC}"

    # c1 (ofport 101) -> c2 (ofport 102) for ICMP
    progress "  c1 -> c2 (ICMP traffic)"
    if ovs-ofctl add-flow "$BRIDGE_NAME" "in_port=101,icmp,actions=output:102" &>/dev/null; then
        progress_done
    else
        progress_fail
        return 1
    fi

    # c2 (ofport 102) -> c3 (ofport 103) for TCP traffic
    progress "  c2 -> c3 (TCP traffic)"
    if ovs-ofctl add-flow "$BRIDGE_NAME" "in_port=102,tcp,actions=output:103" &>/dev/null; then
        progress_done
    else
        progress_fail
        return 1
    fi

    # c3 (ofport 103) -> c1 (ofport 101) for UDP traffic
    progress "  c3 -> c1 (UDP traffic)"
    if ovs-ofctl add-flow "$BRIDGE_NAME" "in_port=103,udp,actions=output:101" &>/dev/null; then
        progress_done
    else
        progress_fail
        return 1
    fi

    # Default drop rule for demonstration
    progress "  Adding default drop rule"
    if ovs-ofctl add-flow "$BRIDGE_NAME" "priority=0,actions=drop" &>/dev/null; then
        progress_done
    else
        progress_fail
        return 1
    fi

    echo -e "\n${GREEN}Example flows added successfully!${NC}"
    echo -e "${YELLOW}These flows demonstrate the value of fixed ofports:${NC}"
    echo -e "  • c1 (ofport 101) -> c2 (ofport 102) for ICMP"
    echo -e "  • c2 (ofport 102) -> c3 (ofport 103) for TCP"
    echo -e "  • c3 (ofport 103) -> c1 (ofport 101) for UDP"
    echo -e "  • All other traffic is dropped"
    echo -e "\n${CYAN}Run './lab.sh' and choose option 6 to view the flows${NC}"
}

# =============================================================================
# Container Management Functions
# =============================================================================

# Enter container shell
enter_container() {
    # Auto-load current playground configuration
    auto_load_current_playground

    local container
    container=$(select_container "Enter shell for which container?")
    [[ -z "$container" ]] && return 1

    if ! is_container_running "$container"; then
        log ERROR "Container $container is not running"
        return 1
    fi

    log INFO "Entering shell for container $container (exit with 'exit' or Ctrl+D)"
    docker exec -it "$container" /bin/bash || \
        docker exec -it "$container" /bin/sh
}

# Execute command in container
exec_in_container() {
    # Auto-load current playground configuration
    auto_load_current_playground

    local container
    container=$(select_container "Execute command in which container?")
    [[ -z "$container" ]] && return 1

    if ! is_container_running "$container"; then
        log ERROR "Container $container is not running"
        return 1
    fi

    read -rp "Command to execute: " cmd
    if [[ -z "$cmd" ]]; then
        log WARN "No command provided"
        return 1
    fi

    log INFO "Executing '$cmd' in container $container"
    docker exec -it "$container" bash -c "$cmd"
}

# Helper function to select container
select_container() {
    local prompt="$1"
    local container

    # Send display output to stderr to avoid command substitution capture
    echo -e "${CYAN}$prompt${NC}" >&2
    echo "Available containers:" >&2
    for i in "${!CONTAINERS[@]}"; do
        local status="stopped"
        if is_container_running "${CONTAINERS[$i]}"; then
            status="running"
        fi
        echo "  $((i+1))) ${CONTAINERS[$i]} ($status)" >&2
    done

    read -rp "Enter container name or number: " choice

    # Check if input is a number
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        local idx=$((choice - 1))
        if [[ $idx -ge 0 && $idx -lt ${#CONTAINERS[@]} ]]; then
            container="${CONTAINERS[$idx]}"
        else
            log ERROR "Invalid container number: $choice"
            return 1
        fi
    else
        container="$choice"
    fi

    if validate_container "$container"; then
        echo "$container"  # Only this goes to stdout for command substitution
        return 0
    else
        return 1
    fi
}

# =============================================================================
# Status and Information Functions
# =============================================================================

# Show comprehensive lab status
show_lab_status() {
    echo -e "\n${CYAN}==================== Lab Status ====================${NC}"

    # Bridge status
    if bridge_exists; then
        echo -e "${GREEN}✓${NC} Bridge: $BRIDGE_NAME (active)"
    else
        echo -e "${RED}✗${NC} Bridge: $BRIDGE_NAME (not found)"
        return 1
    fi

    # Container status
    echo -e "\n${CYAN}Container Status:${NC}"
    for container in "${CONTAINERS[@]}"; do
        if is_container_running "$container"; then
            local ip_info
            ip_info=$(docker exec "$container" ip addr show eth0 2>/dev/null | grep "inet " | awk '{print $2}' | head -1)
            echo -e "${GREEN}✓${NC} $container (running) - IP: ${ip_info:-'N/A'}"
        else
            echo -e "${RED}✗${NC} $container (stopped)"
        fi
    done

    # Port information
    echo -e "\n${CYAN}OVS Port Information:${NC}"
    show_port_info

    # Flow count
    if bridge_exists; then
        local flow_count
        flow_count=$(ovs-ofctl dump-flows "$BRIDGE_NAME" 2>/dev/null | grep -c "^" || echo "0")
        echo -e "\n${CYAN}Active flows:${NC} $flow_count"
    fi

    echo -e "${CYAN}====================================================${NC}\n"
}

# Show detailed port information
show_port_info() {
    if ! bridge_exists; then
        log ERROR "Bridge $BRIDGE_NAME does not exist"
        return 1
    fi

    # Show all ports on the bridge
    local ports_output
    ports_output=$(ovs-vsctl list-ports "$BRIDGE_NAME" 2>/dev/null)

    if [[ -z "$ports_output" ]]; then
        echo "  No ports found on bridge"
        return 0
    fi

    # Get detailed information for each container
    for container in "${CONTAINERS[@]}"; do
        local ofport
        ofport=$(ovs-vsctl --data=bare --no-heading --columns=ofport find Interface external_ids:container_id="$container" external_ids:container_iface=eth0 2>/dev/null)

        if [[ -n "$ofport" && "$ofport" != "[]" ]]; then
            echo -e "  ${container}: ofport=${ofport}"
        else
            echo -e "  ${container}: ${RED}not connected${NC}"
        fi
    done
}

# List running containers with detailed info
list_containers() {
    # Auto-load current playground configuration
    auto_load_current_playground

    echo -e "${CYAN}Container Details:${NC}"

    local format="table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.RunningFor}}"
    local filter="name=^$(printf "%s|" "${CONTAINERS[@]}" | sed 's/|$//')"

    docker ps -a --filter "$filter" --format "$format" 2>/dev/null || \
        log WARN "No containers found matching lab configuration"
}

# Network connectivity test
# Test connectivity between containers
test_connectivity() {
    # Auto-load current playground configuration
    auto_load_current_playground

    echo -e "${CYAN}Testing network connectivity...${NC}"

    local running_containers=()
    for container in "${CONTAINERS[@]}"; do
        if is_container_running "$container"; then
            running_containers+=("$container")
        fi
    done

    if [[ ${#running_containers[@]} -lt 2 ]]; then
        log WARN "Need at least 2 running containers for connectivity test"
        return 1
    fi

    # Simple ping test between containers
    for i in "${!running_containers[@]}"; do
        for j in "${!running_containers[@]}"; do
            if [[ $i -ne $j ]]; then
                local src="${running_containers[$i]}"
                local dst="${running_containers[$j]}"
                local dst_ip
                dst_ip=$(docker exec "$dst" hostname -I 2>/dev/null | awk '{print $1}')

                if [[ -n "$dst_ip" ]]; then
                    progress "Testing $src -> $dst ($dst_ip)"
                    if docker exec "$src" ping -c 1 -W 2 "$dst_ip" &>/dev/null; then
                        progress_done
                    else
                        progress_fail
                    fi
                fi
            fi
        done
    done
}

# =============================================================================
# Interactive Menu System
# =============================================================================

# Display main menu
show_menu() {
    cat << EOF

${CYAN}================= $SCRIPT_NAME =================${NC}
${GREEN} 1)${NC} Enter container shell
${GREEN} 2)${NC} Execute command in container
${GREEN} 3)${NC} Show lab status
${GREEN} 4)${NC} List containers
${GREEN} 5)${NC} Test connectivity
${BLUE} 6)${NC} Show flows
${BLUE} 7)${NC} Flush flows
${BLUE} 8)${NC} Add learning switch flows
${BLUE} 9)${NC} Add example flows (fixed ofports)
${MAGENTA}10)${NC} List playgrounds
${MAGENTA}11)${NC} Show playground help
${YELLOW}12)${NC} Setup/Reload lab
${YELLOW}13)${NC} Destroy lab
${RED}14)${NC} Exit
${CYAN}===============================================${NC}
EOF
}

# Handle menu choice
handle_menu_choice() {
    local choice="$1"

    case "$choice" in
        1) enter_container ;;
        2) exec_in_container ;;
        3) show_lab_status ;;
        4) list_containers ;;
        5) test_connectivity ;;
        6) show_flows ;;
        7) flush_flows ;;
        8) add_learning_flows ;;
        9) add_example_flows ;;
        10) list_playgrounds ;;
        11) show_playground_help ;;
        12) setup_lab ;;
        13) destroy_lab ;;
        14) echo -e "\n${GREEN}Goodbye!${NC}"; exit 0 ;;
        0)
            log INFO "Exiting $SCRIPT_NAME"
            exit 0
            ;;
        *)
            echo -e "\n${RED}Invalid choice. Please try again.${NC}"
            ;;
    esac
}

# Main interactive loop
interactive_mode() {
    while true; do
        show_menu
        read -rp "Choice: " choice

        echo # Add spacing
        handle_menu_choice "$choice"

        echo
        read -rp "Press Enter to continue..." _
    done
}

# =============================================================================
# Main Script Logic
# =============================================================================

main() {
    # Initialize
    check_dependencies

    # Handle command line arguments
    case "${1:-}" in
        setup|--setup|-s)
            check_permissions || exit 1
            # Check if playground is specified as second argument
            if [[ -n "${2:-}" ]]; then
                load_playground "$2" || exit 1
            fi
            setup_lab
            exit 0
            ;;
        destroy|--destroy|-d)
            check_permissions || exit 1
            auto_load_current_playground
            destroy_lab
            exit 0
            ;;
        status|--status)
            check_permissions || exit 1
            auto_load_current_playground
            show_lab_status
            exit 0
            ;;
        list|--list)
            list_playgrounds
            exit 0
            ;;
        help|--help|-h)
            echo "Usage: $0 [COMMAND]"
            echo ""
            echo "Commands:"
            echo "  setup, -s [PLAYGROUND]    Setup the lab environment"
            echo "                           Optional: specify playground name"
            echo "  destroy, -d              Destroy the lab environment"
            echo "  status                   Show lab status"
            echo "  list                     List available playgrounds"
            echo "  help, -h                 Show this help message"
            echo ""
            echo "Setup:"
            echo "  1. Ensure user has docker access (add to docker group if needed)"
            echo "  2. Run './lab.sh setup [playground]' to configure environment"
            echo "  3. After setup, most commands run without sudo"
            echo "     (some network operations may still prompt for sudo)"
            echo ""
            echo "Examples:"
            echo "  ./lab.sh setup simple    # Load simple playground"
            echo "  ./lab.sh setup vlan      # Load VLAN playground"
            echo "  ./lab.sh list            # Show available playgrounds"
            echo ""
            echo "If no command is provided, interactive mode will start."
            echo ""
            echo "Environment Variables:"
            echo "  LOG_LEVEL         Set to DEBUG for verbose output"
            exit 0
            ;;
        "")
            # No arguments - start interactive mode
            check_permissions || exit 1
            log INFO "Starting $SCRIPT_NAME in interactive mode"
            auto_load_current_playground
            interactive_mode
            ;;
        *)
            log ERROR "Unknown command: $1"
            log INFO "Use '$0 help' for usage information"
            exit 1
            ;;
    esac
}

# =============================================================================
# Script Entry Point
# =============================================================================

# Trap to handle script interruption
trap 'echo -e "\n${YELLOW}Script interrupted${NC}"; exit 130' INT TERM

# Run main function with all arguments
main "$@"
