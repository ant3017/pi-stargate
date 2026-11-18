#!/bin/bash
# setup-ssh-via-usb.sh — Configure Raspberry Pi for SSH over USB Ethernet
# Run ONCE on the PI after connecting to laptop via USB
#
# Prerequisites:
#   - Raspberry Pi with OTG USB port (Pi Zero, Pi 4, Pi 5) OR
#   - Pi with g_ether kernel module support
#   - Laptop with USB host port
#   - This script requires sudo
#
# What this does:
#   1. Loads g_ether kernel module for USB Ethernet
#   2. Configures IP address 192.168.7.1 on usb0 (Pi side)
#   3. Ensures sshd is running and enabled
#   4. Makes configuration PERSISTENT across reboots
#
# After running this on the Pi:
#   1. Connect Pi to laptop via USB cable
#   2. Laptop should get IP 192.168.7.2 (via DHCP from pi's usb0)
#   3. SSH: ssh antonio@192.168.7.1

set -e

echo "=== setup-ssh-via-usb.sh ==="
echo "This script configures Raspberry Pi for SSH over USB Ethernet"
echo ""

# Check if running as sudo
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run with sudo: sudo bash $0"
    exit 1
fi

# 1. Load g_ether kernel module
echo "Loading g_ether kernel module..."
modprobe g_ether 2>/dev/null || {
    echo "WARNING: modprobe g_ether failed — checking if already loaded..."
    ls /sys/class/usb0/ 2>/dev/null && echo "usb0 already exists — module may already be loaded" || \
        echo "Could not load g_ether — check kernel support"
}

# 2. Configure USB network interface
echo "Configuring USB network interface..."

# Check if usb0 already has an address
if ip addr show usb0 >/dev/null 2>&1; then
    echo "usb0 already configured:"
    ip addr show usb0 | grep inet
else
    echo "Setting up usb0 with IP 192.168.7.1/24..."
    ip link set usb0 up
    ip addr add 192.168.7.1/24 dev usb0
fi

# 3. Ensure sshd is running
echo "Ensuring SSH daemon is running..."
if systemctl is-active sshd >/dev/null 2>&1 || systemctl is-active ssh >/dev/null 2>&1; then
    echo "SSH already running"
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
else
    echo "Enabling and starting SSH..."
    systemctl enable sshd 2>/dev/null || systemctl enable ssh 2>/dev/null || true
    systemctl start sshd 2>/dev/null || systemctl start ssh 2>/dev/null || true
fi

# 4. Make configuration PERSISTENT across reboots
echo "Making USB Ethernet configuration persistent..."

# Detect which network config system is in use
NETPLAN_CONF=""
INTERFACES_CONF=""

if [ -d /etc/netplan ]; then
    NETPLAN_CONF="/etc/netplan"
    echo "Detected netplan network configuration"
elif [ -f /etc/network/interfaces ]; then
    INTERFACES_CONF="/etc/network/interfaces"
    echo "Detected traditional /etc/network/interfaces"
else
    echo "No standard network config detected — will add to /etc/rc.local or create netplan"
fi

# 4a. Add usb0 to the correct network config file
if [ -n "$NETPLAN_CONF" ]; then
    # Netplan style — find the right .yaml file
    NETPLAN_FILE=$(ls -1 "$NETPLAN_CONF"/*.yaml 2>/dev/null | head -1)
    if [ -n "$NETPLAN_FILE" ]; then
        echo "Adding usb0 to netplan config: $NETPLAN_FILE"
        # Check if usb0 already configured
        if ! grep -q "usb0" "$NETPLAN_FILE" 2>/dev/null; then
            cat >> "$NETPLAN_FILE" << 'NETEOF'

# USB Ethernet over g_ether (auto-added by setup-ssh-via-usb.sh)
usb0:
  addresses: [192.168.7.1/24]
  dhcp4: no
NETEOF
            echo "usb0 configuration added to netplan"
        else
            echo "usb0 already configured in netplan"
        fi
    fi

elif [ -n "$INTERFACES_CONF" ]; then
    # Traditional /etc/network/interfaces style
    echo "Adding usb0 to /etc/network/interfaces"
    if ! grep -q "usb0" "$INTERFACES_CONF" 2>/dev/null; then
        cat >> "$INTERFACES_CONF" << 'INTERFACES_EOF'

# USB Ethernet over g_ether (auto-added by setup-ssh-via-usb.sh)
allow-hotplug usb0
iface usb0 inet static
    address 192.168.7.1
    netmask 255.255.255.0
INTERFACES_EOF
        echo "usb0 configuration added to /etc/network/interfaces"
    else
        echo "usb0 already configured in /etc/network/interfaces"
    fi
else
    # No standard config found — add to /etc/rc.local if it exists
    echo "No standard network config found — attempting /etc/rc.local"
    if [ -f /etc/rc.local ] && ! grep -q "usb0" /etc/rc.local; then
        cat >> /etc/rc.local << 'RCEOF'
# USB Ethernet over g_ether (setup-ssh-via-usb.sh)
ip link set usb0 up 2>/dev/null
ip addr add 192.168.7.1/24 dev usb0 2>/dev/null
RCEOF
        echo "usb0 commands added to /etc/rc.local"
    fi
fi

# 4b. Ensure g_ether module loads on boot
echo "Ensuring g_ether module loads on boot..."

# Check /etc/modules
if [ -f /etc/modules ]; then
    if ! grep -q "g_ether" /etc/modules; then
        echo "g_ether" >> /etc/modules
        echo "Added g_ether to /etc/modules for boot-time loading"
    else
        echo "g_ether already in /etc/modules"
    fi
fi

# Check /boot/firmware/config.txt or /boot/config.txt for Pi OTG
if [ -f /boot/firmware/config.txt ]; then
    CONFIG_FILE="/boot/firmware/config.txt"
elif [ -f /boot/config.txt ]; then
    CONFIG_FILE="/boot/config.txt"
else
    CONFIG_FILE=""
fi

if [ -n "$CONFIG_FILE" ]; then
    # Check for dtparam=usb_otg or dtoverlay
    if ! grep -q "dtparam=usb_otg\|dtoverlay=usb-gadget" "$CONFIG_FILE" 2>/dev/null; then
        echo "Adding dtparam=usb_otg to $CONFIG_FILE"
        echo "dtparam=usb_otg" >> "$CONFIG_FILE"
        echo "   (Pi will use OTG USB port for ethernet gadget on reboot)"
    else
        echo "usb_otg already configured in $CONFIG_FILE"
    fi
fi

# 4c. Create udev rule for persistent device naming
echo "Creating udev rule for persistent usb0..."
cat > /etc/udev/rules.d/99-usb-ethernet.rules << 'UDEOF'
# USB Ethernet gadget (g_ether) — persistent naming
SUBSYSTEM=="usb", ENV{ID_VENDOR_ID}=="1994", ENV{ID_MODEL_ID}=="0010", \
    NAME="usb0", SYMLINK+="net-usb0"
UDEOF
echo "Udev rule created at /etc/udev/rules.d/99-usb-ethernet.rules"

# 5. Summary
echo ""
echo "=== Setup Complete ==="
echo ""
echo "USB Ethernet configured with:"
echo "  Pi IP:      192.168.7.1"
echo ""
echo "Persistence configured for:"
if [ -n "$NETPLAN_CONF" ]; then
    echo "  - Netplan: $NETPLAN_FILE"
fi
if [ -n "$INTERFACES_CONF" ]; then
    echo "  - /etc/network/interfaces: $INTERFACES_CONF"
fi
if [ -f /etc/modules ] && grep -q "g_ether" /etc/modules; then
    echo "  - /etc/modules: g_ernel module"
fi
if [ -n "$CONFIG_FILE" ]; then
    echo "  - $CONFIG_FILE: dtparam=usb_otg"
fi
echo "  - /etc/rc.local: fallback boot scripts"
echo "  - /etc/udev/rules.d/99-usb-ethernet.rules: device naming"
echo ""
echo "Now connect Pi to laptop via USB cable."
echo ""
echo "On laptop, check for new network interface:"
echo "  Linux/macOS:  ifconfig / ip addr | grep -A1 usb0 / en0"
echo "  Windows:    ipconfig /all"
echo ""
echo "SSH from laptop to Pi:"
echo "  ssh antonio@192.168.7.1"
echo ""
echo "Notes:"
echo "  • First connection may take 10-30 seconds as"
echo "    the USB gadget enumerates and DHCP assigns"
echo "  • After reboot, Pi will automatically"
echo "    load g_ether and configure usb0"
echo "  • To disable: remove usb0 configs and"
echo "    remove 'g_ether' from /etc/modules"