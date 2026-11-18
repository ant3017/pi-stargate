#!/bin/bash
# setup-ssh-via-usb.sh — Configure Raspberry Pi for SSH over USB Ethernet
# Run ONCE on the PI after connecting to laptop via USB
#
# Prerequisites:
#   - Raspberry Pi with OTG USB support (Pi Zero, Pi 4, Pi 5)
#   - Laptop with USB host port
#   - This script requires sudo
#
# What this does:
#   1. Ensures g_ernel kernel module is loaded for USB Ethernet (g_ether)
#   2. Configures IP address 192.168.7.1 on usb0 (Pi side, pending gadget enumeration)
#   3. Ensures sshd is running and enabled
#   4. Makes configuration PERSISTENT across reboots
#   5. Sets up USB gadget mode on supported Pi models
#
# After running this on the Pi:
#   1. Connect Pi to laptop via USB cable
#   2. Laptop should get IP 192.168.7.2 (via DHCP from pi's usb0)
#   3. SSH: ssh antonio@192.168.7.1
#
# NOTE: Pi 4 USB gadget mode may require a reboot for full enumeration.

set -e

echo "=== setup-ssh-via-usb.sh ==="
echo "This script configures Raspberry Pi for SSH over USB Ethernet"
echo ""

# Check if running as sudo
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run with sudo: sudo bash $0"
    exit 1
fi

# 1. Ensure g_ernel kernel module is loaded
echo "Loading g_ernel kernel module..."
modprobe g_ether 2>/dev/null || echo "g_ernel module load attempted"
# Module may already be loaded (checked via /proc/modules below)

# 2. Configure USB network interface
echo "Configuring USB network interface..."
if ip addr show usb0 >/dev/null 2>&1; then
    echo "usb0 already configured:"
    ip addr show usb0 | grep inet
else
    echo "Setting up usb0 with IP 192.168.7.1/24 (pending gadget enumeration)..."
    ip link set usb0 up 2>/dev/null || true
    ip addr add 192.168.7.1/24 dev usb0 2>/dev/null || echo "IP pending — will be set on gadget enumeration"
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

# Detect Pi model
MODEL=$(cat /proc/cpuinfo | grep -E '^Model' | cut -d: -f2 | tr -d ' ')
REVISION=$(cat /proc/cpuinfo | grep -E '^Revision' | cut -d: -f2 | tr -d ' ')

echo "Detected Pi: $MODEL (Revision: $REVISION)"

# 4a. Ensure dtparam=usb_otg in config.txt (for Pi Zero/4/5 OTG mode)
echo "Configuring USB OTG mode..."
CONFIG_FILE=""
if [ -f /boot/firmware/config.txt ]; then
    CONFIG_FILE="/boot/firmware/config.txt"
elif [ -f /boot/config.txt ]; then
    CONFIG_FILE="/boot/config.txt"
fi

if [ -n "$CONFIG_FILE" ]; then
    if ! grep -q "dtparam=usb_otg" "$CONFIG_FILE" 2>/dev/null; then
        echo "dtparam=usb_otg" >> "$CONFIG_FILE"
        echo "Added dtparam=usb_otg to $CONFIG_FILE"
    else
        echo "dtparam=usb_otg already in $CONFIG_FILE"
    fi
fi

# 4b. Ensure g_ernel module loads on boot
echo "Ensuring g_ernel module loads on boot..."
if [ -f /etc/modules ]; then
    if ! grep -q "^g_ether" /etc/modules; then
        echo "g_ether" >> /etc/modules
        echo "Added g_ether to /etc/modules for boot-time loading"
    else
        echo "g_ernel already in /etc/modules"
    fi
fi

# 4c. Add usb0 to network config for persistence
echo "Configuring network persistence..."
NETPLAN_CONF=""
INTERFACES_CONF=""

if [ -d /etc/netplan ]; then
    NETPLAN_CONF="/etc/netplan"
elif [ -f /etc/network/interfaces ]; then
    INTERFACES_CONF="/etc/network/interfaces"
fi

if [ -n "$NETPLAN_CONF" ]; then
    NETPLAN_FILE=$(ls -1 "$NETPLAN_CONF"/*.yaml 2>/dev/null | head -1)
    if [ -n "$NETPLAN_FILE" ]; then
        if ! grep -q "usb0" "$NETPLAN_FILE" 2>/dev/null; then
            cat >> "$NETPLAN_FILE" << 'NETEOF'

# USB Ethernet over g_ether (auto-added by setup-ssh-via-usb.sh)
usb0:
  addresses: [192.168.7.1/24]
  dhcp4: no
NETEOF
            echo "usb0 added to netplan config"
        fi
    fi

elif [ -n "$INTERFACES_CONF" ]; then
    if ! grep -q "usb0" "$INTERFACES_CONF" 2>/dev/null; then
        cat >> "$INTERFACES_CONF" << 'INTERFACES_EOF'

# USB Ethernet over g_ether (auto-added by setup-ssh-via-usb.sh)
allow-hotplug usb0
iface usb0 inet static
    address 192.168.7.1
    netmask 255.255.255.0
INTERFACES_EOF
        echo "usb0 added to /etc/network/interfaces"
    fi
fi

# 4d. Pi 4: add rc.local fallback for gadget boot setup
if [ "$MODEL" = "Raspberry Pi 4 Model B" ] || [ "$MODEL" = "Raspberry Pi 4 Model B Rev 1.5" ] || \
   [ "$REVISION" = "b03115" ]; then
    if [ ! -f /etc/rc.local ] || ! grep -q "g_ether" /etc/rc.local 2>/dev/null; then
        cat > /etc/rc.local << 'RCEOF'
#!/bin/sh
# USB Gadget boot setup for Pi 4
modprobe g_ether 2>/dev/null
sleep 2
ip link set usb0 up 2>/dev/null
ip addr add 192.168.7.1/24 dev usb0 2>/dev/null
systemctl start sshd 2>/dev/null || systemctl start ssh 2>/dev/null || true
exit 0
RCEOF
        chmod +x /etc/rc.local
        echo "Created /etc/rc.local for Pi 4 USB gadget boot setup"
    fi
fi

# 5. Summary
echo ""
echo "=== Setup Complete ==="
echo ""
echo "USB Ethernet configured with:"
echo "  Pi IP:      192.168.7.1"
echo ""
echo "Persistence configured:"
if [ -n "$CONFIG_FILE" ]; then
    echo "  - $CONFIG_FILE: dtparam=usb_otg"
fi
if [ -f /etc/modules ] && grep -q "^g_ether" /etc/modules; then
    echo "  - /etc/modules: g_ernel module"
fi
echo "  - Network config: usb0 address 192.168.7.1"
echo "  - SSH daemon: enabled/running"
echo "  - Pi model: $MODEL"
echo ""
echo "Now connect Pi to laptop via USB cable."
echo ""
echo "Expected behavior:"
echo "  • USB gadget enumerates (10-30 seconds)"
echo "  • Laptop gets IP 192.168.7.2 (DHCP from pi's usb0)"
echo "  • SSH from laptop: ssh antonio@192.168.7.1"
echo ""
echo "If USB gadget does not work:"
echo "  1. Reboot the Pi: sudo reboot"
echo "  2. Verify 'dtparam=usb_otg' is in config.txt"
echo "  3. Check 'dmesg | grep -i usb' for errors"
echo "  4. For Pi 4: ensure you're using the USB data port (not the powered port for peripherals)"
echo ""
echo "Important: On Pi 4, the first boot after running this script"
echo "may require a reboot for the USB gadget to fully enumerate."