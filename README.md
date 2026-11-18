# pi-config — deploy bundle for the Pi WiFi bridge

Mirrors the Pi filesystem: `files/etc/...` deploys to `/etc/...`,
`files/usr/...` to `/usr/...`. `install.ps1` (Windows) scp's the bundle to
the Pi and runs `install.sh` there via ssh.

## 1. What to change — the easy way

Edit the **variables at the top of `install.ps1`** only. The script
stages a copy in `%TEMP%`, substitutes them into the configs, and uploads —
`files/` templates are never modified:

| Variable | Goes into | Effect |
|---|---|---|
| `$Server` | — | SSH target. `192.168.255.3` via tunnel, `192.168.50.1` via AP |
| `$ApSsid` / `$ApPassword` | `hostapd.conf` | name + WPA2 password of `sg0` AP (8-63 chars) |
| `$RouterSsid` / `$RouterPassword` | `60-wifi.yaml` | first uplink network (portal can add more later) |
| `$WgPrivateKey` | `wh0.conf` `[Interface]` | this Pi's WG private key |
| `$WgAddress` | `wh0.conf` `[Interface]` | Pi's tunnel IP (`192.168.255.3/24`) |
| `$WgPeerPublicKey` | `wh0.conf` `[Peer]` | server's public key |
| `$WgEndpoint` | `wh0.conf` `[Peer]` | server `host:port` |
| `$WgAllowedIps` | `wh0.conf` `[Peer]` | `0.0.0.0/0` = all traffic through tunnel |
| `$WgKeepalive` | `wh0.conf` `[Peer]` | NAT keepalive seconds |

## 2. What to change — per file (things not in install.ps1)

| Want to change… | Edit file | Key/lines |
|---|---|---|
| AP subnet / Pi's AP-side IP | `files/etc/systemd/network/10-ap0.network` | `Address=` |
| DHCP range handed to laptop | `files/etc/dnsmasq.d/ap0.conf` | `dhcp-range=` |
| DNS given to AP clients | `files/etc/dnsmasq.d/ap0.conf` | `dhcp-option=6`, `server=` |
| Extra uplink networks | `files/etc/netplan/60-wifi.yaml` | add under `access-points:` (keep `band: 2.4GHz`) |
| AP channel when no uplink | `files/etc/hostapd/hostapd.conf` | `channel=` (sync script overwrites once wlan0 associates) |
| Channel-sync polling rate | `files/etc/systemd/system/watch-ap-channel.timer` | `OnUnitActiveSec=` |
| Portal page/behavior | `pi-config/pi-portal/wifi_portal.py` | `PAGE` template, `STA`/`AP`/`WG`/`AP_IP` constants |
| Packages installed on Pi | `install.sh` | `PKGS=` line |
| iptables rules | `install.sh` | the `iptables -C/-A` block near the end |
| WireGuard fail-closed vs split | `files/etc/wireguard/wh0.conf` | `AllowedIPs=` |

## 3. Deploy

```powershell
cd pi-config
.\install.ps1
```

Requires OpenSSH client (built into Windows 10+). Remote install runs
with sudo — password prompt expected. Re-running is safe (idempotent):
same files = same result, services get re-enabled.

## 4. What gets installed on the Pi

- `etc/netplan/60-wifi.yaml` — wlan0 STA uplink, `band: 2.4GHz` (required — AP+STA share one radio/channel)
- `etc/hostapd/hostapd.conf` + `etc/default/hostapd` — AP on virtual `ap0` (no `country_code`, no `acs` — both were fatal bugs)
- `etc/systemd/system/ap0.service` — creates `ap0` at boot
- `etc/systemd/network/10-ap0.network` — `192.168.50.1/24` on `ap0`
- `etc/dnsmasq.d/ap0.conf` — DHCP + DNS for AP clients only
- `etc/sysctl.d/90-bridge.conf` — `ip_forward=1`
- `etc/NetworkManager/conf.d/99-unmanaged-wlan.conf` — NetworkManager hands off wlan0/ap0
- `etc/wireguard/wh0.conf` + `wg-quick@wh0` — tunnel; `AllowedIPs=0.0.0.0/0` puts ALL routed traffic (Pi + forwarded ap0 clients) through `wh0` regardless of which uplink (wlan0/eth0) carries it
- `usr/local/sbin/sync-ap-channel` + `watch-ap-channel` + `.timer` — AP channel auto-follows wlan0's channel
- `etc/networkd-dispatcher/routable.d/50-ap-channel` — instant channel re-sync on association
- `usr/local/sbin/wifi_portal.py` + `wifi-portal.service` — captive provisioning portal on `http://192.168.50.1/` (from `pi-portal/`)
- iptables: `FORWARD ap0<->wh0` + `MASQUERADE -o wh0`
- resolv.conf fix: disables dnsmasq's resolvconf hook (would hijack Pi's DNS to a dead `127.0.0.1` stub)

## 5. Package prerequisites on the Pi

`install.sh` installs these automatically when the Pi has internet
(USB tether, uplink, or otherwise):

```bash
netplan.io hostapd dnsmasq iw curl wpasupplicant wireguard \
python3-flask python3-yaml networkd-dispatcher iptables-persistent
```

No internet → script warns, skips apt, installs files anyway.

## 6. Snapshot / restore on the Pi

Both run **on the Pi** from inside this folder:

```bash
sudo bash capture.sh   # live config -> files/ (+ files.manifest modes)
sudo bash restore.sh   # files/ -> live paths, backs up to *.bak-YYYYMMDD-HHMMSS
sudo bash restore.sh --dry-run   # show changes, write nothing
```

`capture.sh` makes this repo reflect what is *actually deployed*. New
files you want tracked: add them to the `FILES` list inside `capture.sh`.

## 7. Verify after deploy

```bash
iw dev                                  # ap0 (AP) + wlan0 (managed), same channel
systemctl status hostapd                # AP-ENABLED
curl http://192.168.50.1/status         # portal, from the Pi
wg show                                 # tunnel handshake < 2min old
```

Laptop: join `sg0` → gets `192.168.50.x` → portal pops (no uplink)
or traffic exits via `wh0` (online).
