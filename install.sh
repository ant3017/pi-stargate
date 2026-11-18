#!/bin/bash
# Runs ON THE PI (via ssh). Copies staged files from /tmp/pi-config-files
# into place, then enables services. Must be able to sudo.
set -e
SRC=/tmp/pi-config-files

die() { echo "ERROR: $*" >&2; exit 1; }
[ -d "$SRC" ] || die "$SRC not found — run install.ps1 first"

# ---- dependencies -------------------------------------------------
PKGS="netplan.io hostapd dnsmasq iw curl wpasupplicant wireguard \
      python3-flask python3-yaml networkd-dispatcher iptables-persistent"

if ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 || ping -c1 -W3 deb.debian.org >/dev/null 2>&1; then
    echo "Installing packages..."
    sudo apt-get update -qq || true
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $PKGS \
        || echo "WARNING: some packages failed — install manually later: $PKGS"
else
    echo "WARNING: no internet detected — skipping apt install."
    echo "         Needed packages: $PKGS"
    echo "         Continuing with file install anyway."
fi
# -------------------------------------------------------------------

inst() { # <relpath> <mode>
    sudo install -D -m "$2" "$SRC/$1" "/$1"
    echo "installed /$1"
}

inst etc/netplan/60-wifi.yaml                                  600
inst etc/hostapd/hostapd.conf                                  644
inst etc/default/hostapd                                       644
inst etc/systemd/system/hostapd.service.d/override.conf        644
inst etc/dnsmasq.d/ap0.conf                                    644
inst etc/systemd/system/ap0.service                            644
inst etc/systemd/system/watch-ap-channel.service               644
inst etc/systemd/system/watch-ap-channel.timer                 644
inst etc/systemd/system/wifi-portal.service                    644
inst etc/systemd/network/10-ap0.network                        644
inst etc/sysctl.d/90-bridge.conf                               644
inst etc/wireguard/wh0.conf                                    600
inst etc/NetworkManager/conf.d/99-unmanaged-wlan.conf          644
inst etc/resolvconf/resolv.conf.d/head                         644
inst etc/resolvconf/resolv.conf.d/tail                         644
inst etc/iptables/rules.v4                                     644
inst etc/networkd-dispatcher/routable.d/50-ap-channel          755
inst usr/local/sbin/sync-ap-channel                            755
inst usr/local/sbin/watch-ap-channel                           755
inst usr/local/sbin/wifi_portal.py                             755

# ---- fix resolv.conf hijack -----------------------------------
# dnsmasq ships /etc/resolvconf/update.d/dnsmasq which writes
# "nameserver 127.0.0.1" into resolv.conf — but OUR dnsmasq only serves
# AP clients (bind-interfaces ap0), nothing listens on 127.0.0.1:53,
# so the Pi itself loses all name resolution. Disable the hook.
if [ -e /etc/resolvconf/update.d/dnsmasq ]; then
    sudo mv /etc/resolvconf/update.d/dnsmasq \
            /etc/resolvconf/update.d/dnsmasq.disabled
    sudo resolvconf -u 2>/dev/null || true
    echo "disabled dnsmasq resolvconf hook"
fi
# stop dnsmasq re-registering lo.dnsmasq (nameserver 127.0.0.1) on restart
if [ -f /etc/default/dnsmasq ] && ! grep -q '^IGNORE_RESOLVCONF=yes' /etc/default/dnsmasq; then
    echo 'IGNORE_RESOLVCONF=yes' | sudo tee -a /etc/default/dnsmasq >/dev/null
    echo "set IGNORE_RESOLVCONF=yes in /etc/default/dnsmasq"
fi
# openresolv ignores resolv.conf.d/head — pin 1.1.1.1 first via resolvconf.conf
# (name_servers entries are written ahead of interface records;
#  name_servers_append would put them last instead)
if [ -f /etc/resolvconf.conf ] && ! grep -q '^name_servers[=_ ]' /etc/resolvconf.conf; then
    echo 'name_servers=1.1.1.1' | sudo tee -a /etc/resolvconf.conf >/dev/null
    sudo resolvconf -u 2>/dev/null || true
    echo "prepended 1.1.1.1 via /etc/resolvconf.conf"
fi
# fallback: if resolv.conf still has no real (non-127) nameserver, pin one
if ! grep -vE '^nameserver[[:space:]]+127\.' /etc/resolv.conf 2>/dev/null \
        | grep -qE '^nameserver[[:space:]]+[0-9]'; then
    grep -vE '^nameserver[[:space:]]+127\.' /etc/resolv.conf > /tmp/rc.$$ 2>/dev/null || true
    { cat /tmp/rc.$$ 2>/dev/null; echo "nameserver 1.1.1.1"; } | sudo tee /etc/resolv.conf >/dev/null
    rm -f /tmp/rc.$$
    echo "pinned nameserver 1.1.1.1 in resolv.conf"
fi
# ---------------------------------------------------------------

sudo systemctl daemon-reload
sudo sysctl --system >/dev/null
sudo systemctl unmask hostapd 2>/dev/null || true

# Sync AP country code and channel from wlan0 before starting services
sudo /usr/local/sbin/sync-ap-channel || echo "WARNING: sync-ap-channel failed"

sudo systemctl restart NetworkManager || true
sudo systemctl restart systemd-networkd
sudo netplan apply || echo "netplan apply failed — check yaml + ovsdb-server"

sudo systemctl enable --now wg-quick@wh0         || true
sudo systemctl enable --now ap0.service          || true
sudo systemctl enable --now dnsmasq              || true
sudo systemctl enable --now hostapd              || true
sudo systemctl enable --now watch-ap-channel.timer
sudo systemctl enable --now wifi-portal          || true
sudo systemctl enable --now networkd-dispatcher  || true

# NAT rules for the AP -> WireGuard (iface is wh0 on this device)
sudo iptables -C FORWARD -i ap0 -o wh0 -j ACCEPT 2>/dev/null || \
    sudo iptables -A FORWARD -i ap0 -o wh0 -j ACCEPT
sudo iptables -C FORWARD -i wh0 -o ap0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    sudo iptables -A FORWARD -i wh0 -o ap0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
sudo iptables -t nat -C POSTROUTING -o wh0 -j MASQUERADE 2>/dev/null || \
    sudo iptables -t nat -A POSTROUTING -o wh0 -j MASQUERADE
sudo netfilter-persistent save 2>/dev/null || \
    echo "NOTE: run 'apt install iptables-persistent' + 'netfilter-persistent save' to persist rules"

echo "----- verify -----"
iw dev | grep -E "Interface|type"
systemctl is-active hostapd ap0.service dnsmasq wifi-portal watch-ap-channel.timer || true
echo "Done. AP should beacon on wlan0's channel (or 11 until first sync)."
