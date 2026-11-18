#!/bin/bash
# capture.sh — run ON THE PI.
# Pulls the live config files from their real locations into ./files/
# and records each file's permission bits in ./files.manifest, so this
# repo always mirrors what is actually deployed.
#
#   sudo bash capture.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HERE/files"
MANIFEST="$HERE/files.manifest"

# Files tracked by this repo — add new ones here.
FILES="
etc/netplan/50-eth0.yaml
etc/netplan/60-wifi.yaml
etc/hostapd/hostapd.conf
etc/default/hostapd
etc/systemd/system/hostapd.service.d/override.conf
etc/dnsmasq.d/ap0.conf
etc/dnsmasq.d/usb0.conf
etc/systemd/system/ap0.service
etc/systemd/system/watch-ap-channel.service
etc/systemd/system/watch-ap-channel.timer
etc/systemd/system/wifi-portal.service
etc/systemd/network/10-ap0.network
etc/sysctl.d/90-bridge.conf
etc/wireguard/wh0.conf
etc/NetworkManager/conf.d/99-unmanaged-wlan.conf
etc/resolvconf/resolv.conf.d/head
etc/resolvconf/resolv.conf.d/tail
etc/resolvconf/update.d/dnsmasq.disabled
etc/resolvconf.conf
etc/default/dnsmasq
etc/iptables/rules.v4
etc/networkd-dispatcher/routable.d/50-ap-channel
usr/local/sbin/sync-ap-channel
usr/local/sbin/watch-ap-channel
usr/local/sbin/wifi_portal.py
boot/firmware/config.txt
boot/firmware/cmdline.txt
"

: > "$MANIFEST"
fail=0
for rel in $FILES; do
    if [ -f "/$rel" ]; then
        mkdir -p "$DEST/$(dirname "$rel")"
        cp -p "/$rel" "$DEST/$rel"
        printf '%s %s\n' "$rel" "$(stat -c %a "/$rel")" >> "$MANIFEST"
        echo "captured /$rel  (mode $(stat -c %a "/$rel"))"
    else
        echo "SKIP  /$rel (missing)" >&2
        fail=1
    fi
done
echo "-----"
echo "Snapshot written to $DEST (+ files.manifest)"
[ $fail -eq 0 ] || echo "NOTE: some files were missing — see SKIP lines above"
