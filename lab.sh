#!/bin/bash
set -euo pipefail

# =============================================================================
# OVS Lab Manager - Enhanced Version
# =============================================================================
# A comprehensive script for managing OpenVSwitch laboratory environments
# with Docker containers for network testing and experimentation.
# =============================================================================

# Load OVS helper functions
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
if [[ -f "$SCRIPT_DIR/lib/ovs-helpers.sh" ]]; then
    source "$SCRIPT_DIR/lib/ovs-helpers.sh"
fi

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

    # Use helper function to find the interface name
    local interface_name
    interface_name=$(get_port_name "$container")

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

# Store additional playground metadata (name, version, description snippet)
set_playground_metadata() {
    bridge_exists || return 0
    [[ -z "$CURRENT_PLAYGROUND" ]] && return 0
    local args=()
    [[ -n "$PLAYGROUND_NAME" ]] && args+=(external_ids:playground_name="$PLAYGROUND_NAME")
    [[ -n "$PLAYGROUND_VERSION" ]] && args+=(external_ids:playground_version="$PLAYGROUND_VERSION")
    if [[ -n "$PLAYGROUND_DESCRIPTION" ]]; then
        local desc="${PLAYGROUND_DESCRIPTION:0:120}"
        args+=(external_ids:playground_desc="$desc")
    fi
    if [[ ${#args[@]} -gt 0 ]]; then
        ovs-vsctl set bridge "$BRIDGE_NAME" "${args[@]}" &>/dev/null || return 0
        log DEBUG "Playground metadata annotated"
    fi
}

# Get current playground from bridge external_ids
get_current_playground() {
    if bridge_exists; then
        # Be tolerant: if key missing, ovs-vsctl exits non-zero; we must not propagate under set -e
        local val
        val=$(ovs-vsctl --data=bare --no-heading get bridge "$BRIDGE_NAME" external_ids:playground 2>/dev/null || true)
        # Trim quotes/newlines
        printf '%s' "$val" | tr -d '"' || true
    fi
    return 0
}

# Auto-load current playground configuration
auto_load_current_playground() {
    local current_pg=""
    current_pg=$(get_current_playground || true)

    if [[ -n "$current_pg" && "$current_pg" != "[]" ]]; then
        log INFO "Detected active playground: $current_pg"
        if load_playground "$current_pg"; then
            return 0
        else
            log WARN "Failed to load detected playground: $current_pg (falling back to default)"
            set_default_config
            return 0
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
        # Single transaction: create bridge + set fail_mode + initial playground external_id
        if ovs-vsctl \
            -- add-br "$BRIDGE_NAME" \
            -- set bridge "$BRIDGE_NAME" fail_mode=secure external_ids:playground="${CURRENT_PLAYGROUND:-default}" &>/dev/null; then
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

    # Persist playground state early
    if [[ -n "$CURRENT_PLAYGROUND" ]]; then
        set_playground_state "$CURRENT_PLAYGROUND"
        set_playground_metadata || true
    else
        set_playground_state "default"
    fi

    # Hooks post-setup
    run_playground_hooks post

    # Apply flows owned by playground (after state & metadata saved)
    apply_playground_flows "$CURRENT_PLAYGROUND"

    log SUCCESS "OVS lab setup complete!"
    if [[ -n "$CURRENT_PLAYGROUND" ]]; then
        log INFO "Playground: $CURRENT_PLAYGROUND ($PLAYGROUND_NAME)"
    fi
    log INFO "You can now run lab commands without sudo"
    show_lab_status
}

# Playground hook execution (hooks.d/*.sh)
run_playground_hooks() {
    local stage="$1" # pre|post
    local playground_path="$PLAYGROUND_DIR/$CURRENT_PLAYGROUND"
    local hooks_dir="$playground_path/hooks.d"
    [[ -z "$CURRENT_PLAYGROUND" || ! -d "$hooks_dir" ]] && return 0
    # stage filtering can be added later; for now run all executable scripts
    for script in $(find "$hooks_dir" -maxdepth 1 -type f -name "*.sh" | sort); do
        if [[ -x "$script" ]]; then
            log INFO "Running hook: $(basename "$script")"
            if ! "$script" "$stage" "$BRIDGE_NAME"; then
                log WARN "Hook $(basename "$script") reported non-zero exit"
            fi
        fi
    done
}

# Apply flows from playground flows directory
apply_playground_flows() {
    auto_load_current_playground
    if ! bridge_exists; then
        log ERROR "Bridge $BRIDGE_NAME does not exist"
        return 1
    fi
    local playground="${1:-$CURRENT_PLAYGROUND}"
    if [[ -z "$playground" || "$playground" == "default" ]]; then
        log WARN "No specific playground selected; skipping external flows"
        return 0
    fi
    local flows_dir="$PLAYGROUND_DIR/$playground/flows"
    if [[ ! -d "$flows_dir" ]]; then
        log INFO "No flows directory: $flows_dir"
        return 0
    fi
    local flow_files=()
    while IFS= read -r -d '' f; do flow_files+=("$f"); done < <(find "$flows_dir" -maxdepth 1 -type f ! -name 'README*' -print0 | sort -z)
    if [[ ${#flow_files[@]} -eq 0 ]]; then
        log INFO "No flow files to apply in $flows_dir"
        return 0
    fi
    log INFO "Applying flows from $flows_dir (${#flow_files[@]} files)"
    # Flush existing flows first (playground owns flows)
    flush_flows
    local applied=0 failed=0
    for file in "${flow_files[@]}"; do
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%%#*}" # strip trailing comment
            line="${line//[$'\t\r\n ']}" # trim simple whitespace ends for empty detection
            if [[ -z "$line" ]]; then
                continue
            fi
            if ovs-ofctl add-flow "$BRIDGE_NAME" "$line" 2>/dev/null; then
                ((applied++))
            else
                log WARN "Failed flow: $line"
                ((failed++))
            fi
        done < "$file"
    done
    log SUCCESS "Flows applied: $applied (failed: $failed)"
    return 0
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

# Execute command in container (non-interactive)
# Usage: exec_container_command [--interactive|-i] [--tty|-t] <container> <command> [args...]
exec_container_command() {
    local interactive=false
    local tty=false
    local docker_flags=()
    
    # Parse flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --interactive|-i)
                interactive=true
                docker_flags+=("-i")
                shift
                ;;
            --tty|-t)
                tty=true
                docker_flags+=("-t")
                shift
                ;;
            --it|-it)
                interactive=true
                tty=true
                docker_flags+=("-it")
                shift
                ;;
            -*)
                log ERROR "Unknown flag: $1"
                log INFO "Supported flags: --interactive/-i, --tty/-t, --it/-it"
                return 1
                ;;
            *)
                break
                ;;
        esac
    done
    
    local container="$1"
    shift # Remove container name from arguments

    if [[ -z "$container" ]]; then
        log ERROR "Container name required"
        log INFO "Usage: exec [--interactive|-i] [--tty|-t] <container> <command> [args...]"
        return 1
    fi

    # Auto-load current playground configuration
    auto_load_current_playground

    # Validate container name
    if ! validate_container "$container"; then
        return 1
    fi

    if ! is_container_running "$container"; then
        log ERROR "Container $container is not running"
        return 1
    fi

    # Build docker exec command
    local docker_cmd=(docker exec)
    
    # Add flags if specified
    if [[ ${#docker_flags[@]} -gt 0 ]]; then
        docker_cmd+=("${docker_flags[@]}")
    fi
    
    docker_cmd+=("$container")
    docker_cmd+=("$@")

    # Show what we're executing
    if [[ $interactive == true || $tty == true ]]; then
        log INFO "Executing interactive command in container $container: $*"
    else
        log INFO "Executing command in container $container: $*"
    fi
    
    # Execute the command
    "${docker_cmd[@]}"
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

    # Playground information
    local current_pg
    current_pg=$(get_current_playground)
    if [[ -n "$current_pg" && "$current_pg" != "[]" && "$current_pg" != "default" ]]; then
        echo -e "${MAGENTA}Active Playground:${NC} $current_pg"
        if [[ -n "$PLAYGROUND_NAME" ]]; then
            echo -e "${MAGENTA}Description:${NC} $PLAYGROUND_NAME"
        fi
    elif [[ "$current_pg" == "default" ]]; then
        echo -e "${MAGENTA}Active Playground:${NC} ${YELLOW}default (no specific playground)${NC}"
    else
        echo -e "${MAGENTA}Active Playground:${NC} ${YELLOW}none detected${NC}"
    fi

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

    # Get detailed information for each container using helper function
    for container in "${CONTAINERS[@]}"; do
        local ofport
        ofport=$(get_container_ofport "$container")

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
${MAGENTA} 8)${NC} List playgrounds
${MAGENTA} 9)${NC} Show playground help
${MAGENTA}10)${NC} Apply playground flows
${YELLOW}11)${NC} Setup/Reload lab
${YELLOW}12)${NC} Destroy lab
${RED}13)${NC} Exit
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
        8) list_playgrounds ;;
        9) show_playground_help ;;
        10) apply_playground_flows ;;
        11) setup_lab ;;
        12) destroy_lab ;;
        13) echo -e "\n${GREEN}Goodbye!${NC}"; exit 0 ;;
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
    log INFO "Entering interactive mode (Ctrl+D to exit)"
    while true; do
        set +e
        show_menu
        if ! read -rp "Choice: " choice; then
            log INFO "EOF received. Exiting interactive mode."; break
        fi
        set -e
        echo
        if ! handle_menu_choice "$choice"; then
            log WARN "Action returned non-zero"
        fi
        echo
        set +e
        read -rp "Press Enter to continue..." _ || { log INFO "EOF. Bye."; break; }
        set -e
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
        exec)
            check_permissions || exit 1
            if [[ $# -lt 2 ]]; then
                echo "Usage: $0 exec [--interactive|-i] [--tty|-t] <container> <command> [args...]"
                echo ""
                echo "Flags:"
                echo "  --interactive, -i    Keep STDIN open even if not attached"
                echo "  --tty, -t           Allocate a pseudo-TTY"
                echo "  --it, -it           Shorthand for --interactive --tty"
                echo ""
                echo "Examples:"
                echo "  $0 exec c1 ping 10.0.0.2                    # Basic command"
                echo "  $0 exec -it c1 bash                         # Interactive shell"
                echo "  $0 exec --tty c1 top                        # With TTY for colors"
                echo "  $0 exec --interactive c1 cat > /tmp/file    # Keep STDIN open"
                echo ""
                auto_load_current_playground >/dev/null 2>&1
                echo "Available containers: ${CONTAINERS[*]}"
                exit 1
            fi
            shift # Remove 'exec' from arguments
            exec_container_command "$@"
            exit $?
            ;;
        flows)
            check_permissions || exit 1
            shift || true
            if [[ -n "${1:-}" ]]; then
                load_playground "$1" || exit 1
            else
                auto_load_current_playground
            fi
            apply_playground_flows "$CURRENT_PLAYGROUND"
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
            echo "  setup, -s [PLAYGROUND]           Setup the lab environment"
            echo "                                  Optional: specify playground name"
            echo "  destroy, -d                     Destroy the lab environment"
            echo "  status                          Show lab status"
            echo "  exec [flags] <container> <cmd>  Execute command in container"
            echo "  flows [PLAYGROUND]              Apply (reload) flows from playground flows/ directory"
            echo "  list                            List available playgrounds"
            echo "  help, -h                        Show this help message"
            echo ""
            echo "Exec flags:"
            echo "  --interactive, -i               Keep STDIN open even if not attached"
            echo "  --tty, -t                       Allocate a pseudo-TTY"
            echo "  --it, -it                       Shorthand for --interactive --tty"
            echo ""
            echo "Setup:"
            echo "  1. Ensure user has docker access (add to docker group if needed)"
            echo "  2. Run './lab.sh setup [playground]' to configure environment"
            echo "  3. After setup, most commands run without sudo"
            echo "     (some network operations may still prompt for sudo)"
            echo ""
            echo "Examples:"
            echo "  ./lab.sh setup simple                      # Load simple playground"
            echo "  ./lab.sh setup vlan                        # Load VLAN playground"
            echo "  ./lab.sh exec c1 ping 10.0.0.2             # Execute ping in container c1"
            echo "  ./lab.sh exec -it vlan10-c1 bash           # Interactive shell in container"
            echo "  ./lab.sh exec --tty c1 htop                # Run htop with TTY support"
            echo "  ./lab.sh exec --interactive c1 'cat > file' # Keep STDIN open for input"
            echo "  ./lab.sh list                              # Show available playgrounds"
            echo "  ./lab.sh flows simple                      # Apply flows of simple playground"
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
