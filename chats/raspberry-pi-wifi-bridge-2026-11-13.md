# Raspberry Pi WiFi Bridge — Full Session Notes (2026-11-13)

Device: Raspberry Pi "stargate" running Raspberry Pi OS/Debian (user `antonio`).
Goal: laptop connects to Pi's WiFi AP → traffic routed through WireGuard.
Uplink: same WiFi radio also acts as STA to the router (concurrent AP+STA).

Interface map discovered during the session:

- `wlan0` — WiFi STA to router (netplan/wpa_supplicant, DHCP)
- `ap0` — virtual AP interface for the laptop (hostapd + dnsmasq)
- `wh0` — **WireGuard interface (named wh0, NOT wg0)**, 192.168.255.3
- `eth0` — exists but unused (no carrier)
- `usb0` — phone USB tether, used for temporary internet/apt

---

## Core constraint

One radio = one channel. `ap0` and `wlan0` must share the channel that `wlan0`
associated on. Verify chip support:

```bash
iw list | grep -A5 "valid interface combinations"
# need: #{ managed } <= 1, #{ AP } <= 1 in the SAME combination block
```

## Working architecture

| Piece | Tool | Config |
|---|---|---|
| STA uplink | netplan → wpa_supplicant → networkd | `/etc/netplan/60-wifi.yaml` |
| AP | hostapd on `ap0` | `/etc/hostapd/hostapd.conf` |
| AP IP | systemd-networkd `.network` file | `/etc/systemd/network/10-ap0.network` |
| DHCP for laptop | dnsmasq (DHCP only, `port=0`) | `/etc/dnsmasq.d/ap0.conf` |
| NAT/FWD | iptables → `wh0` | masquerade on `wh0` |
| Channel auto-adapt | `sync-ap-channel` + 30s timer | `/usr/local/sbin/` |

---

## Configs that worked

### netplan `/etc/netplan/60-wifi.yaml`

```yaml
network:
  version: 2
  renderer: networkd
  wifis:
    wlan0:
      dhcp4: true
      access-points:
        "RouterSSID":
          password: "routerpass"
          band: 2.4GHz          # critical: locks STA to 2.4GHz
```

`band: 2.4GHz` forces the STA off 5 GHz. Alternative for old netplan:
`freq_list=2412 2417 ... 2462` in a manual wpa_supplicant conf.

### hostapd `/etc/hostapd/hostapd.conf`

```ini
interface=ap0
driver=nl80211
ssid=PiBridge
hw_mode=g
channel=11              # overwritten by sync-ap-channel
ieee80211n=1
wmm_enabled=1
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
wpa_passphrase=YourAPPassword
rsn_pairwise=CCMP
ctrl_interface=/var/run/hostapd
ctrl_interface_group=0
```

**Do NOT set `country_code=`** — see pitfalls.

`/etc/default/hostapd`: `DAEMON_CONF="/etc/hostapd/hostapd.conf"`,
then `systemctl unmask hostapd && systemctl enable --now hostapd`.

### Virtual AP interface — `/etc/systemd/system/ap0.service`

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

### ap0 IP — `/etc/systemd/network/10-ap0.network`

```ini
[Match]
Name=ap0

[Network]
Address=192.168.50.1/24
```

### dnsmasq `/etc/dnsmasq.d/ap0.conf`

```ini
interface=ap0
bind-interfaces
port=0
dhcp-range=192.168.50.10,192.168.50.100,255.255.255.0,24h
dhcp-option=3,192.168.50.1
dhcp-option=6,1.1.1.1
```

### Forwarding + NAT (note `wh0`, not `wg0`)

```bash
sysctl -w net.ipv4.ip_forward=1   # persist in /etc/sysctl.d/90-bridge.conf

iptables -A FORWARD -i ap0 -o wh0 -j ACCEPT
iptables -A FORWARD -i wh0 -o ap0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -t nat -A POSTROUTING -o wh0 -j MASQUERADE

netfilter-persistent save
```

If `wh0` isn't a full-tunnel default route, policy-route AP clients into it:

```bash
ip rule add iif ap0 table 200
ip route add default dev wh0 table 200
```

---

## Auto-adapt: AP follows wlan0's channel

### `/usr/local/sbin/sync-ap-channel`

```bash
#!/bin/bash
CHAN=$(iw dev wlan0 info 2>/dev/null | awk '/channel/{print $2; exit}')
if [ -z "$CHAN" ] || [ "$CHAN" -gt 13 ]; then
    echo "sync-ap-channel: wlan0 not on 2.4GHz (chan=${CHAN:-none}), AP stays down"
    exit 0
fi
sed -i "s/^channel=.*/channel=$CHAN/" /etc/hostapd/hostapd.conf
systemctl restart hostapd
```

### `/usr/local/sbin/watch-ap-channel` (poller)

```bash
#!/bin/bash
STATE=/run/ap-channel
CHAN=$(iw dev wlan0 info 2>/dev/null | awk '/channel/{print $2; exit}')
LAST=$(cat "$STATE" 2>/dev/null)
[ "$CHAN" = "$LAST" ] && exit 0
echo "$CHAN" > "$STATE"
/usr/local/sbin/sync-ap-channel
```

### `/etc/systemd/system/watch-ap-channel.timer` + `.service`

```ini
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/watch-ap-channel
```

```ini
[Timer]
OnBootSec=30
OnUnitActiveSec=30
[Install]
WantedBy=timers.target
```

Optional event trigger: `networkd-dispatcher` hook at
`/etc/networkd-dispatcher/routable.d/50-ap-channel` calling
`/usr/local/sbin/sync-ap-channel` when `IFACE=wlan0`.

**Never** call `systemctl restart hostapd` from a `hostapd.service`
`ExecStartPre` — it kills the starting unit (signal=TERM) and latches
"Start request repeated too quickly" (fix: `systemctl reset-failed hostapd`).

---

## Pitfalls hit during the session (all real, in order)

1. **`netplan apply` → "Cannot call openvswitch: ovsdb-server.service is not running"**
   netplan probes `ovs-vsctl`. Fix: start `ovsdb-server` or remove the
   `openvswitch-*` package that provides the binary.

2. **`wlan0: Failed to initiate sched scan`**
   Radio busy — stale AP-mode state or a second `wpa_supplicant`.
   Fixes: `iw dev wlan0 set type managed` (bring iface down first),
   `killall wpa_supplicant && netplan apply`, check
   `ps -ef | grep wpa_supplicant` shows exactly ONE process.

3. **hostapd dies at `UNINITIALIZED->COUNTRY_UPDATE`**
   `country_code=` in hostapd.conf conflicts with the regdomain the kernel
   adopted from the router's country IE. Fix: **remove `country_code`** —
   hostapd inherits the kernel domain.

4. **hostapd dies right after `ACS-STARTED`**
   `channel=acs` cannot survey while a STA is associated (scanning off-channel
   would drop the connection). Fix: **hardcode `channel=`**, never ACS.

5. **AP invisible despite no errors — channel 44 / 5230 MHz**
   Router put `wlan0` on a 5 GHz DFS channel; `iw list` shows 5230 MHz
   `disabled`/`no IR` — the radio physically cannot beacon there.
   Fix: force STA to 2.4 GHz (`band: 2.4GHz` or `freq_list`), AP follows.

6. **`temporary failure resolving deb.debian.org`**
   DNS only: `echo nameserver 1.1.1.1 > /etc/resolv.conf`, or check
   `systemd-resolved`, or re-plug USB tether for internet.

7. **Access recovery when AP is down**
   - USB gadget mode: `dtoverlay=dwc2` in config.txt +
     `modules-load=dwc2,g_ether` in cmdline.txt → SSH over `usb0` (RNDIS)
   - USB phone tether → instant internet via `usb0` for apt

---

## Verification

```bash
sudo systemctl status hostapd --no-pager -l   # AP-ENABLED in journal
iw dev ap0 info        # ssid + channel
iw dev wlan0 info      # same channel as ap0
sudo iw dev wlan0 scan | grep PiBridge        # self-beacon visible
```

Laptop: connect to `PiBridge` → gets `192.168.50.x` → `ping 192.168.50.1` →
`curl ifconfig.me` shows the WireGuard exit IP.

## Remaining fragility

- 5 GHz-only routers = no AP (by design, `band: 2.4GHz` guard)
- Boot order: STA must associate before hostapd finds a usable channel —
  the 30s `watch-ap-channel.timer` covers this regardless of order
- ~half throughput on the shared radio
- USB WiFi dongle would remove all of this permanently
