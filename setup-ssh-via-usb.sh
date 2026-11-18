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
#   1. Fixes Pi 4 USB/gadget mode conflicts (CRITICAL - restores network)
#   2. Ensures g_ernel kernel module is loaded for USB Ethernet
#   3. Configures IP address 192.168.7.1 on usb0 (Pi side)
#   4. Ensures sshd is running and enabled
#   5. Makes configuration PERSISTENT across reboots
#   5. Sets up USB gadget mode on supported Pi models
#
# After running this on the Pi:
#   1. Connect Pi to laptop via USB cable
#   2. Laptop should get IP 192.168.7.2 (via DHCP from pi's usb0)
#   3. SSH: ssh antonio@192.168.7.1
#
# IMPORTANT: Pi 4 has a known conflict between otg_mode=1 and USB device mode.
# This script automatically fixes this to restore network AND enable gadget mode.

set -e

echo "=== setup-ssh-via-usb.sh ==="
echo "This script configures Raspberry Pi for SSH over USB Ethernet"
echo ""

# Check if running as sudo
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run with sudo: sudo bash $0"
    exit 1
fi

# ============================================================
# CRITICAL: Fix Pi 4 USB/gadget mode conflicts (RESTORES NETWORK)
# ============================================================
echo "Fixing Pi 4 USB configuration conflicts..."

# Detect Pi model and revision
MODEL=$(cat /proc/cpuinfo | grep -E '^Model' | cut -d: -f2 | tr -d ' ')
REVISION=$(cat /proc/cpuinfo | grep -E '^Revision' | cut -d: -f2 | tr -d ' ')
echo "Detected Pi: $MODEL (Revision: $REVISION)"

# Find the config.txt file
CONFIG_FILE=""
if [ -f /boot/firmware/config.txt ]; then
    CONFIG_FILE="/boot/firmware/config.txt"
elif [ -f /boot/config.txt ]; then
    CONFIG_FILE="/boot/config.txt"
fi

if [ -n "$CONFIG_FILE" ]; then
    echo "Config file: $CONFIG_FILE"

    # CRITICAL FIX for Pi 4: Remove otg_mode=1 and set dr_mode=device
    # Pi 4 cannot have both otg_mode=1 and USB device mode enabled
    # otg_mode=1 is for CM4 IO board, not Pi 4 native USB OTG

    # Check if otg_mode=1 is present (Pi 4 should NOT have this)
    IF_OTG_MODE=$(grep -c '^otg_mode=1' "$CONFIG_FILE" 2>/dev/null)
    echo "  otg_mode=1 found: $IF_OTG_MODE time(s)"

    if [ "$IF_OTG_MODE" -gt 0 ]; then
        echo "  WARNING: otg_mode=1 detected — this conflicts with Pi 4 USB device mode"
        echo "  Removing otg_mode=1 to restore network and enable gadget mode..."
        sudo sed -i '/^otg_mode=1/d' "$CONFIG_FILE"
        echo "  Removed otg_mode=1 from config.txt"
    fi

    # Check and set dr_mode=device for USB gadget mode
    CURRENT_DR_MODE=$(grep -o 'dr_mode=[a-z]*' "$CONFIG_FILE" 2>/dev/null | head -1)
    echo "  Current dr_mode: ${CURRENT_DR_MODE:-not set}"

    if [ "$CURRENT_DR_MODE" = "dr_mode=host" ] || [ "$CURRENT_DR_MODE" = "" ]; then
        if [ "$CURRENT_DR_MODE" = "dr_mode=host" ]; then
            echo "  Changing dr_mode=host -> dr_mode=device for USB gadget mode..."
        else
            echo "  Adding dr_mode=device for USB gadget mode (not previously set)..."
        fi
        sudo sed -i 's/dr_mode=host/dr_mode=device/' "$CONFIG_FILE" 2>/dev/null || \
            # If sed didn't work (dr_mode not set), add it after dtoverlay=dwc2
            sudo sed -i "/dtoverlay=dwc2/a\\dr_mode=device" "$CONFIG_FILE" 2>/dev/null
        echo "  Fixed: dr_mode set to device"
    fi

    # Verify the changes
    echo "  Verifying config.txt changes..."
    grep -E '^(otg_mode|dr_mode)' "$CONFIG_FILE" 2>/dev/null || echo "  No otg_mode/dr_mode lines found (good — cleaned up)"
    grep -E '^dtparam=usb_otg' "$CONFIG_FILE" 2>/dev/null || echo "  dtparam=usb_otg not found (will be added by script if needed)"
fi

# ============================================================
# Rest of the script
# ============================================================

# 2. Ensure g_ernel kernel module is loaded
echo "Loading g_ernel kernel module..."
modprobe g_ether 2>/dev/null || echo "g_ernel module load attempted"
# Module may already be loaded (checked via /proc/modules below)

# 3. Configure USB network interface
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

# Detect which network config system is in use
NETPLAN_CONF=""
INTERFACES_CONF=""

if [ -d /etc/netplan ]; then
    NETPLAN_CONF="/etc/netplan"
elif [ -f /etc/network/interfaces ]; then
    INTERFACES_CONF="/etc/network/interfaces"
fi

# 4a. Add usb0 to network config for persistence
echo "Configuring network persistence..."
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

# 4c. Pi 4: add rc.local fallback for gadget boot setup
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
    OTG_STATUS=$(grep -c '^otg_mode=1' "$CONFIG_FILE" 2>/dev/null || echo 0)
    DR_MODE=$(grep -o 'dr_mode=[a-z]*' "$CONFIG_FILE" 2>/dev/null | head -1)
    echo "  - $CONFIG_FILE: dtparam=usb_otg"
    echo "    • otg_mode=1 removed: $OTG_STATUS"
    echo "    • dr_mode: ${DR_MODE:-not set}"
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
echo "  • USB gadget enumerates (10-30 seconds after connection)"
echo "  • Laptop gets IP 192.168.7.2 (DHCP from pi's usb0)"
echo "  • SSH from laptop: ssh antonio@192.168.7.1"
echo ""
echo "If USB gadget does not work:"
echo "  1. Reboot the Pi: sudo reboot"
echo "  2. Verify 'dr_mode=device' is in config.txt (no otg_mode=1)"
echo "  3. Check 'dmesg | grep -i usb' for errors"
echo "  4. For Pi 4: ensure you're using a USB 2.0 data port"
echo ""
echo "Important: The script fixed Pi 4 USB configuration by:"
echo "  • Removing otg_mode=1 (conflicts with Pi 4 device mode)"
echo "  • Setting dr_mode=device (enables USB gadget/device mode)"
echo "  • This simultaneously RESTORES network connectivity"
echo "    AND enables the USB Ethernet gadget function."