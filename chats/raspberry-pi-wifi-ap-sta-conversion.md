# Raspberry Pi WiFi Bridge: Concurrent AP + STA (Router via WiFi)

Context: Pi running Ubuntu acts as a bridge — laptop connects to its WiFi AP,
uplink goes to router (was eth0, goal is WiFi) → WireGuard tunnel.
wlan0 is currently a NetworkManager-managed AP. No eth0 available; SSH into the
Pi happens over the AP itself.

## Key constraint

A single WiFi radio can run STA + AP simultaneously **only if the chipset/driver
supports it**, and both interfaces must share the **same channel**.

Check support:

```bash
iw list | grep -A5 "valid interface combinations"
# Need: #{ managed } <= 1, #{ AP } <= 1 in one combination block
```

Built-in Broadcom/Cypress chips on Pi 3/4/5 generally support this with
`channels <= 1` (same-channel constraint).

## Useful diagnostic commands

```bash
iw dev                              # list wireless interfaces and their types
iw dev wlan0 info                   # type AP/managed + channel
nmcli device status                 # who manages wlan0 (NetworkManager?)
nmcli connection show --active      # active profiles (e.g. "Hotspot")
ps -ef | grep hostapd | grep -v grep   # NM spawns hostapd internally
cat /etc/netplan/*.yaml             # netplan wifi config if present
systemctl status hostapd            # absent = probably NM-managed hotspot
```

---

## Option A — Concurrent sta0 while keeping NM hotspot (try first, zero risk)

The AP pins the channel; the STA must reach the router on the **same channel**.

```bash
iw dev wlan0 info | grep channel                                 # AP channel
sudo iw dev wlan0 scan | grep -B8 "YourRouterSSID" | grep channel # router channel
```

If they match (or after fixing the router's channel):

```bash
sudo iw dev wlan0 interface add sta0 type managed
nmcli device wifi connect "RouterSSID" password "routerpass" ifname sta0
ip -br a            # sta0 should get a router-side IP
ping -c2 1.1.1.1
```

NM hotspot uses `ipv4.method=shared`, which NATs laptop traffic out the default
route — once sta0 has the route, the laptop may already have internet.

Install packages while connected:

```bash
sudo apt update && sudo apt install -y netplan.io hostapd dnsmasq iw iptables-persistent
```

Persist sta0 across reboots — `/etc/systemd/system/sta0.service`:

```ini
[Unit]
Before=NetworkManager.service
After=sys-subsystem-net-devices-wlan0.device

[Service]
Type=oneshot
ExecStart=/usr/sbin/iw dev wlan0 interface add sta0 type managed
RemainAfterExit=yes

[Install]
WantedBy=network-pre.target
```

```bash
sudo systemctl enable sta0.service
```

Update NAT rules to masquerade on `sta0` instead of `eth0`; verify
`ip route get <wg-endpoint-ip>` goes via `sta0`, not `wg0`.

---

## Option B — Full conversion to hostapd + wpa_supplicant (via netplan)

**WARNING:** do this over console/eth0, or via a detached script — reconfiguring
wlan0 kills SSH-over-AP.

Architecture: `wlan0` = STA (netplan-managed), `ap0` = AP (hostapd + dnsmasq).
Set the router to a fixed channel first (e.g. 6).

### 1. Packages

```bash
sudo apt install -y hostapd dnsmasq iw
```

### 2. Free wlan0 from NetworkManager

```bash
nmcli con delete Hotspot   # actual connection name
```

`/etc/NetworkManager/NetworkManager.conf` — add:

```ini
[keyfile]
unmanaged-devices=interface-name:wlan0;interface-name:ap0
```

```bash
sudo systemctl restart NetworkManager
```

### 3. wlan0 as STA — `/etc/netplan/60-wifi.yaml`

```yaml
network:
  version: 2
  renderer: networkd
  wifis:
    wlan0:
      dhcp4: true
      access-points:
        "YourRouterSSID":
          password: "your-router-password"
```

```bash
sudo chmod 600 /etc/netplan/60-wifi.yaml
sudo netplan apply
iw dev wlan0 link    # should show Connected
```

### 4. Virtual AP interface — `/etc/systemd/system/ap0.service`

```ini
[Unit]
Description=Virtual AP interface on wlan0
After=sys-subsystem-net-devices-wlan0.device
Before=hostapd.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/iw dev wlan0 interface add ap0 type __ap
RemainAfterExit=yes
ExecStop=/usr/sbin/iw dev ap0 del

[Install]
WantedBy=multi-user.target
```

Static IP — `/etc/systemd/network/10-ap0.network`:

```ini
[Match]
Name=ap0

[Network]
Address=192.168.50.1/24
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now ap0.service
sudo systemctl restart systemd-networkd
```

### 5. hostapd — `/etc/hostapd/hostapd.conf`

```ini
interface=ap0
driver=nl80211
ssid=PiBridge
hw_mode=g
channel=6              # MUST equal router channel
ieee80211n=1
wmm_enabled=1
country_code=GB
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
wpa_passphrase=YourAPPassword
rsn_pairwise=CCMP
```

`/etc/default/hostapd`:

```ini
DAEMON_CONF="/etc/hostapd/hostapd.conf"
```

```bash
sudo systemctl unmask hostapd
sudo systemctl enable --now hostapd
# success = "ap0: AP-ENABLED"
```

### 6. DHCP for AP clients — `/etc/dnsmasq.d/ap0.conf`

```ini
interface=ap0
bind-interfaces
port=0
dhcp-range=192.168.50.10,192.168.50.100,255.255.255.0,24h
dhcp-option=3,192.168.50.1
dhcp-option=6,1.1.1.1
```

```bash
sudo systemctl enable --now dnsmasq
```

### 7. Forwarding + NAT

```bash
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/90-bridge.conf
sudo sysctl --system

sudo iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE
sudo iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE
sudo iptables -A FORWARD -i ap0 -o wlan0 -j ACCEPT
sudo iptables -A FORWARD -i ap0 -o wg0 -j ACCEPT
sudo iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

sudo apt install -y iptables-persistent
sudo netfilter-persistent save
```

(Replace/remove the old eth0 rules; check `sudo iptables -t nat -S`.)

### 8. WireGuard

```bash
ip route get <wg-endpoint-ip>   # must egress via wlan0, NOT wg0
sudo wg show                    # handshake should still occur
```

Update any policy-routing rules that referenced eth0 → wlan0/ap0.

### 9. Rollback

```bash
sudo systemctl disable --now hostapd dnsmasq ap0.service
sudo rm /etc/netplan/60-wifi.yaml /etc/systemd/network/10-ap0.network
# remove unmanaged-devices block, recreate NM hotspot, netplan apply
```

---

## No-internet bootstrap (SSH over the AP, no eth0)

Since reboot restores the NM hotspot (autoconnect), a reboot is the safety net.
Run the conversion detached so SSH death doesn't kill it:

```bash
sudo systemd-run --unit=wificonvert bash /root/convert.sh
```

`/root/convert.sh` skeleton:

```bash
#!/bin/bash
shutdown -r +15 &          # failsafe: reboot restores the AP if we hang

nmcli con down Hotspot
nmcli device wifi connect "RouterSSID" password "routerpass"
sleep 5
apt update && apt install -y netplan.io hostapd dnsmasq iw iptables-persistent

# ... write config files, enable services, netplan apply ...

shutdown -c                # success — cancel reboot
```

Reconnect the laptop to the new AP SSID afterwards.

## Gotchas

- Single radio = ~half throughput, one shared channel.
- If the router auto-selects channels, fix it — a channel change breaks both sides.
- Boot order matters: STA associates first (pins channel), hostapd follows.
- A $10 USB WiFi dongle removes all constraints — separate radio, any channel.
