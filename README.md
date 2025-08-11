# OVS Lab Manager

A comprehensive lab management tool for OpenVSwitch (OVS) network experimentation using Docker containers. This tool provides an easy-to-use interface for setting up, managing, and experimenting with various network topologies and configurations.

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Shell](https://img.shields.io/badge/shell-bash-green.svg)
![Platform](https://img.shields.io/badge/platform-linux-lightgrey.svg)

## Features

### 🚀 Core Features
- **Modular Playground System**: Pre-configured network scenarios for different learning objectives
- **Interactive & Non-Interactive Modes**: Both CLI and menu-driven interfaces
- **Container Management**: Automated Docker container lifecycle management
- **OVS Integration**: Deep integration with OpenVSwitch for advanced networking
- **Fixed Port Mapping**: Consistent OpenFlow port assignments for reproducible experiments

### 🔧 Advanced Features
- **VLAN Support**: Complete VLAN configuration including access and trunk ports
- **Permission Management**: Automated OVS permission setup for non-root users
- **Flow Management**: Playground-owned OpenFlow rules loaded from per-playground flows/ directories (no global example injection)
- **Hooks System**: Optional hooks.d scripts for custom pre/post actions
- **Network Testing**: Automated connectivity testing between containers
- **Extensible Architecture**: Easy to add new playgrounds and configurations

## Quick Start

### Prerequisites

```bash
# Required packages (Ubuntu/Debian)
sudo apt update
sudo apt install docker.io openvswitch-switch

# Add user to docker group
sudo usermod -aG docker $USER
# Log out and back in for group changes to take effect

# Install ovs-docker utility
sudo wget -O /usr/local/bin/ovs-docker \
  https://raw.githubusercontent.com/openvswitch/ovs/master/utilities/ovs-docker
sudo chmod +x /usr/local/bin/ovs-docker
```

### Installation

```bash
git clone https://github.com/guohao117/ovs-lab.git
cd ovs-lab
chmod +x lab.sh
```

### Basic Usage

```bash
# List available playgrounds
./lab.sh list

# Setup a simple 3-container environment
./lab.sh setup simple

# Setup VLAN segmentation lab
./lab.sh setup vlan

# Check lab status
./lab.sh status

# Execute commands in containers
./lab.sh exec c1 ping 10.0.0.2
./lab.sh exec -it vlan10-c1 bash

# Start interactive mode
./lab.sh
```

## Available Playgrounds

### Simple Playground
A basic 3-container setup for fundamental network testing:
- **Containers**: c1, c2, c3
- **Network**: Basic L2 connectivity
- **Use Case**: Learning OpenFlow basics, connectivity testing

### VLAN Playground
Advanced VLAN segmentation demonstration:
- **VLAN 10**: vlan10-c1, vlan10-c2 (access ports)
- **VLAN 20**: vlan20-c1, vlan20-c2 (access ports)  
- **Trunk Ports**: trunk-c1, trunk-c2 (carry both VLANs)
- **Use Case**: VLAN isolation, trunk configuration, network segmentation

## Command Reference

### Setup Commands
```bash
./lab.sh setup [playground]    # Setup lab environment
./lab.sh destroy              # Destroy lab environment  
./lab.sh status               # Show current status
./lab.sh list                 # List available playgrounds
```

### Container Management
```bash
# Execute commands
./lab.sh exec <container> <command>           # Basic execution
./lab.sh exec -it <container> bash            # Interactive shell
./lab.sh exec --tty <container> htop          # TTY support
./lab.sh exec --interactive <container> cat   # Keep STDIN open
```

### Flow / Hooks Management
Playgrounds can now fully own their flow rules and custom logic:
```
playgrounds/<name>/
  config.sh          # Variables & metadata
  flows/             # *.flow or any files with rule lines (one rule per line)
  hooks.d/           # Optional executable *.sh scripts (ordered by filename)
```
Usage:
```bash
./lab.sh flows <playground>   # Flush existing flows and apply playground flow files
```
Rules: non-empty, non-comment lines are passed directly to `ovs-ofctl add-flow` after an automatic flush.

### OpenFlow Rules
```bash
# Apply (or reapply) flows defined by current playground
./lab.sh flows simple

# Manually inspect flows
./lab.sh status   # shows flow count
./lab.sh          # interactive menu -> Show flows
```

## Architecture

```
ovs-lab/
├── lab.sh                     # Main lab management script
├── lib/
│   └── ovs-helpers.sh        # OVS utility functions library
└── playgrounds/
    ├── simple/
    │   └── config.sh         # Simple playground configuration
    └── vlan/
        └── config.sh         # VLAN playground configuration
```

### Key Components

#### Lab Manager (`lab.sh`)
- Command-line interface and interactive menu
- Container lifecycle management
- OVS bridge and flow management
- Permission and dependency checking

#### OVS Helpers Library (`lib/ovs-helpers.sh`)
- Low-level OVS operations
- Container-to-port mapping
- VLAN configuration utilities
- Network validation functions

#### Playground System
- Modular configuration system
- Environment-specific setup/cleanup hooks
- Extensible architecture for new scenarios

## Examples

### Basic Network Testing
```bash
# Setup simple environment
./lab.sh setup simple

# Test connectivity
./lab.sh exec c1 ping -c 3 10.0.0.2

# Show network interfaces
./lab.sh exec c1 ip addr show
```

### VLAN Experimentation
```bash
# Setup VLAN environment
./lab.sh setup vlan

# Test same VLAN connectivity (should work)
./lab.sh exec vlan10-c1 ping -c 3 10.10.0.2

# Test cross-VLAN connectivity (should fail)
./lab.sh exec vlan10-c1 ping -c 3 10.20.0.1

# Monitor trunk traffic
./lab.sh exec --tty trunk-c1 tcpdump -i eth0 -n
```

### OpenFlow Rules
```bash
# Apply (or reapply) flows defined by current playground
./lab.sh flows simple

# Manually inspect flows
./lab.sh status   # shows flow count
./lab.sh          # interactive menu -> Show flows
```

## Creating Custom Playgrounds

### 1. Create Playground Directory
```bash
mkdir playgrounds/mylab
```

### 2. Create Configuration File
```bash
cat > playgrounds/mylab/config.sh << 'EOF'
#!/bin/bash

# Load OVS helper functions
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SCRIPT_DIR/../../lib/ovs-helpers.sh"

# Playground metadata
PLAYGROUND_NAME="My Custom Lab"
PLAYGROUND_DESCRIPTION="Custom network topology for specific testing"
PLAYGROUND_VERSION="1.0"

# Container configuration
CONTAINERS=(web db router)

# Network configuration
CONTAINER_CONFIG["web"]="192.168.1.10/24:192.168.1.1"
CONTAINER_CONFIG["db"]="192.168.2.10/24:192.168.2.1" 
CONTAINER_CONFIG["router"]="192.168.1.1/24:"

# OpenFlow port mapping
CONTAINER_OFPORT["web"]="10"
CONTAINER_OFPORT["db"]="20"
CONTAINER_OFPORT["router"]="30"

# Custom setup function
playground_setup() {
    echo "Setting up custom lab..."
    # Add your custom configuration here
    return 0
}

# Custom cleanup function
playground_cleanup() {
    echo "Cleaning up custom lab..."
    return 0
}

# Help function
playground_help() {
    cat << EOH
My Custom Lab Help
==================
This playground demonstrates...
EOH
}
EOF
```

### Optional: Add Flows
```bash
mkdir -p playgrounds/mylab/flows
cat > playgrounds/mylab/flows/base.rules <<'EOF'
# Example flow rules (one per line, comments ignored)
priority=100,in_port=10,actions=output:30
priority=100,in_port=20,actions=output:30
priority=90,in_port=30,ip,nw_dst=192.168.1.10,actions=output:10
priority=90,in_port=30,ip,nw_dst=192.168.2.10,actions=output:20
priority=0,actions=drop
EOF

# Apply them
./lab.sh flows mylab
```
### Optional: Hooks
```bash
mkdir -p playgrounds/mylab/hooks.d
cat > playgrounds/mylab/hooks.d/90-post.sh <<'EOF'
#!/bin/bash
echo "[mylab hook] Post-setup running: bridge=$2"
EOF
chmod +x playgrounds/mylab/hooks.d/90-post.sh
```

### 3. Use Your Playground
```bash
./lab.sh setup mylab
```

## Troubleshooting

### Common Issues

#### Permission Denied
```bash
# Ensure user is in docker group
sudo usermod -aG docker $USER
# Log out and back in

# Run setup to configure OVS permissions
./lab.sh setup
```

#### OVS Not Found
```bash
# Install OpenVSwitch
sudo apt install openvswitch-switch

# Start OVS service
sudo systemctl start openvswitch-switch
```

#### Container Network Issues
```bash
# Check bridge status
sudo ovs-vsctl show

# Verify container connectivity
./lab.sh status

# Restart lab environment
./lab.sh destroy
./lab.sh setup [playground]
```

### Debug Mode
```bash
# Enable verbose logging
LOG_LEVEL=DEBUG ./lab.sh setup vlan
```

## Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feature-name`
3. Make your changes and test thoroughly
4. Submit a pull request with detailed description

### Development Guidelines
- Follow existing code style and patterns
- Add appropriate error handling
- Update documentation for new features
- Test with multiple playground configurations

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- OpenVSwitch community for excellent documentation
- Docker team for containerization platform
- Network engineering community for testing and feedback

## Support

- 📖 [Documentation](https://github.com/yourusername/ovs-lab/wiki)
- 🐛 [Issue Tracker](https://github.com/yourusername/ovs-lab/issues)
- 💬 [Discussions](https://github.com/yourusername/ovs-lab/discussions)

---

**Happy Networking! 🌐**
