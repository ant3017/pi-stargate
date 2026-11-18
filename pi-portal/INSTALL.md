# WiFi Provisioning Portal — install

Gives the laptop a captive-portal page on the AP that lists upstream WiFi
networks, takes a password, tests it by associating, and saves working
credentials to the netplan yaml. If the upstream network itself has a
captive portal (hotel/cafe), AP traffic is routed via wlan0 until the
upstream login completes, then switched to `wh0`.

## Install on the Pi

```bash
sudo apt install -y python3-flask python3-yaml curl

sudo cp wifi_portal.py /usr/local/sbin/wifi_portal.py
sudo chmod +x /usr/local/sbin/wifi_portal.py

sudo cp wifi-portal.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now wifi-portal
```

Requirements already in place: `ap0` exists with `192.168.50.1/24`,
`dnsmasq` serving DHCP on ap0, `net.ipv4.ip_forward=1`.

## How it works

- **Page:** `http://192.168.50.1/` from any AP client.
- **Scan:** `iw dev wlan0 scan` — deduped, sorted by signal. All added
  networks get `band: 2.4GHz` automatically (required for AP+STA sharing).
- **Test:** writes the SSID+password into `/etc/netplan/60-wifi.yaml`,
  runs `netplan apply`, polls association up to 30 s. Failure → entry
  removed and previous config restored.
- **Upstream captive portal:** `clients3.google.com/generate_204` probe.
  If hijacked (non-204 response) → AP→wlan0 forwarding (direct, not WG)
  so the laptop hits the upstream portal. User opens any HTTP page to log in.
- **No uplink:** dnsmasq gets `address=/#/192.168.50.1` (catch-all DNS →
  portal) so Windows/Android/Apple captive detection auto-opens the page.
  Removed again once online.
- **Manager loop** (`wifi_portal.py` `manager_loop`, every 30 s):
  online → route wh0, no hijack | portal → route wlan0, no hijack |
  offline → DNS hijack on.

## Check it

```bash
systemctl status wifi-portal
curl http://192.168.50.1/status        # from the Pi
# from laptop on the AP: browse to http://192.168.50.1/
```

## Notes / limits

- Runs as root (needs netplan/iptables/iw). Only reachable on the AP side
  in practice — still, don't expose `ap0` to untrusted users.
- Scan happens while wlan0 may be associated; on the single radio this is
  a brief pause, fine.
- Wrong-password detection = association timeout (~30 s), not an instant
  "bad password" reply — driver doesn't report it that cleanly.
- If netplan `band` is unsupported on your version, the app falls back
  gracefully (it just stores password + band key; if `netplan apply`
  errors, remove `band` handling in `add_network` and use `freq_list`
  in a raw wpa_supplicant conf instead).
