#!/usr/bin/env python3
"""
WiFi provisioning captive portal for the Pi bridge (stargate).

Serves on the AP interface. Lets the laptop user:
  - see all WiFi networks visible to wlan0
  - pick one and enter a password
  - have the password tested by actually associating
  - have working credentials saved into the netplan yaml for next boot

Upstream captive portals (hotels etc.): when the Pi is associated but the
upstream network still demands a portal login, AP clients are forwarded
directly via wlan0 (not the WireGuard tunnel) so the upstream portal can
hijack them and show its login page. Once the internet check passes,
traffic is switched back to wh0.

When the Pi has no usable uplink at all, dnsmasq on ap0 is switched into
DNS-hijack mode (all DNS -> AP IP) so the laptop OS auto-opens this page.

Run as root (needs iw/netplan/iptables/dnsmasq access).
"""

import os
import re
import subprocess
import threading
import time

import yaml
from flask import Flask, redirect, render_template_string, request, jsonify

# ------------------------------------------------------------------ config
STA = "wlan0"                 # wifi uplink interface
AP = "ap0"                    # AP interface
WG = "wh0"                    # WireGuard interface (NOTE: wh0 on this device)
UPLINK_CANDIDATES = ("eth0", "usb0", STA)   # ordered: first hit wins
AP_IP = "192.168.50.1"
PORT = 80
NETPLAN_FILE = "/etc/netplan/60-wifi.yaml"
HIJACK_FILE = "/etc/dnsmasq.d/portal-hijack.conf"
CONNECT_TIMEOUT = 30          # seconds to wait for association
MANAGER_INTERVAL = 30         # seconds between state re-checks
PROBE_URL = "http://clients3.google.com/generate_204"

app = Flask(__name__)
_last_msg = ""                # shown on the page after connect attempts


# ----------------------------------------------------------------- helpers
def sh(*cmd, timeout=15):
    """Run a command, return CompletedProcess. Never raises."""
    try:
        return subprocess.run(cmd, capture_output=True, text=True,
                              timeout=timeout)
    except Exception as e:
        class R:
            returncode = 1
            stdout = ""
            stderr = str(e)
        return R()


def sta_ssid():
    """SSID wlan0 is associated to, or None."""
    out = sh("iw", "dev", STA, "link").stdout
    if "Not connected" in out:
        return None
    m = re.search(r"SSID:\s*(.+)", out)
    return m.group(1).strip() if m else None


def sta_channel():
    out = sh("iw", "dev", STA, "info").stdout
    m = re.search(r"channel\s+(\d+)", out)
    return int(m.group(1)) if m else None


def uplink_iface():
    """Interface carrying the default route (uplink), excl. ap0/wh0.
    Works for wifi AND wired uplinks — returns e.g. 'eth0' or 'wlan0'."""
    out = sh("ip", "-o", "route", "show", "default").stdout
    devs = [m.group(1) for m in re.finditer(r"dev\s+(\S+)", out)]
    for cand in UPLINK_CANDIDATES:
        if cand in devs:
            return cand
    return None


def wg_state():
    """'connected' (handshake <3min) | 'stale' (iface up, old handshake)
    | 'down' (no iface or peer never answered)."""
    if sh("ip", "link", "show", WG).returncode != 0:
        return "down"
    r = sh("wg", "show", WG, "latest-handshakes")
    ts = 0
    for tok in r.stdout.split():
        if tok.isdigit():
            ts = max(ts, int(tok))
    if ts == 0:
        return "down"               # interface up but peer never answered
    return "connected" if (time.time() - ts) < 180 else "stale"


def scan_networks():
    """Return [{ssid, signal, secured}] deduplicated, strongest first."""
    out = sh("iw", "dev", STA, "scan", timeout=20).stdout
    nets = {}
    cur = None
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("BSS "):
            cur = {"ssid": None, "signal": -999, "secured": False}
        elif cur is not None:
            if line.startswith("SSID:"):
                cur["ssid"] = line[5:].strip()
            elif line.startswith("signal:"):
                m = re.search(r"(-\d+)", line)
                if m:
                    cur["signal"] = int(m.group(1))
            elif line.startswith("capability:") and "Privacy" in line:
                cur["secured"] = True
            elif line.startswith(("RSN:", "WPA:")):
                cur["secured"] = True
            if cur["ssid"] is not None:
                s = cur["ssid"]
                if s and (s not in nets or nets[s]["signal"] < cur["signal"]):
                    nets[s] = dict(cur)
                cur = None
    return sorted(nets.values(), key=lambda n: -n["signal"])


def load_netplan():
    if not os.path.exists(NETPLAN_FILE):
        return {"network": {"version": 2, "renderer": "networkd",
                            "wifis": {STA: {"dhcp4": True,
                                            "access-points": {}}}}}
    with open(NETPLAN_FILE) as f:
        return yaml.safe_load(f)


def save_netplan(cfg):
    with open(NETPLAN_FILE, "w") as f:
        yaml.safe_dump(cfg, f, default_flow_style=False)
    os.chmod(NETPLAN_FILE, 0o600)


def add_network(ssid, password):
    """Add/update SSID in netplan yaml. Returns True if it already existed."""
    cfg = load_netplan()
    aps = (cfg.setdefault("network", {})
              .setdefault("wifis", {})
              .setdefault(STA, {"dhcp4": True})
              .setdefault("access-points", {}))
    existed = ssid in aps
    entry = {}
    if password:
        entry["password"] = password
    entry["band"] = "2.4GHz"     # keeps us off 5GHz (AP needs 2.4 channel)
    aps[ssid] = entry
    save_netplan(cfg)
    return existed


def remove_network(ssid):
    cfg = load_netplan()
    aps = (cfg.get("network", {}).get("wifis", {})
              .get(STA, {}).get("access-points", {}))
    if ssid in aps:
        del aps[ssid]
        save_netplan(cfg)


def try_connect(timeout=CONNECT_TIMEOUT):
    """netplan apply, then poll for association."""
    sh("netplan", "apply")
    deadline = time.time() + timeout
    while time.time() < deadline:
        if sta_ssid():
            return True
        time.sleep(2)
    return False


def upstream_state():
    """'offline' | 'portal' | 'online'"""
    if not (sta_ssid() or uplink_iface()):
        return "offline"
    r = sh("curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
           "--max-time", "6", PROBE_URL, timeout=10)
    code = r.stdout.strip()
    if code == "204":
        return "online"
    if code and code != "000":
        return "portal"          # got hijacked HTTP response
    return "offline"             # associated but nothing reachable


# ------------------------------------------------- routing / dns switching
def _ipt(*args):
    return subprocess.run(["iptables"] + list(args),
                          capture_output=True).returncode == 0


def _rule_add(*rule):
    if not _ipt("-C", *rule):
        _ipt("-A", *rule)


def _rule_del(*rule):
    while _ipt("-C", *rule):
        _ipt("-D", *rule)


def _nat_add(*rule):
    if not _ipt("-t", "nat", "-C", *rule):
        _ipt("-t", "nat", "-A", *rule)


def _nat_del(*rule):
    while _ipt("-t", "nat", "-C", *rule):
        _ipt("-t", "nat", "-D", *rule)


def _fwd_pair(out_iface):
    _rule_add("FORWARD", "-i", AP, "-o", out_iface, "-j", "ACCEPT")
    _rule_add("FORWARD", "-i", out_iface, "-o", AP, "-m", "conntrack",
              "--ctstate", "RELATED,ESTABLISHED", "-j", "ACCEPT")
    _nat_add("POSTROUTING", "-o", out_iface, "-j", "MASQUERADE")


def _fwd_remove(out_iface):
    _rule_del("FORWARD", "-i", AP, "-o", out_iface, "-j", "ACCEPT")
    _rule_del("FORWARD", "-i", out_iface, "-o", AP, "-m", "conntrack",
              "--ctstate", "RELATED,ESTABLISHED", "-j", "ACCEPT")
    _nat_del("POSTROUTING", "-o", out_iface, "-j", "MASQUERADE")


def set_route_mode(mode):
    """'wg' = laptop traffic via WireGuard; 'direct' = via uplink (portal login)."""
    if mode == "direct":
        _fwd_remove(WG)
        _fwd_pair(uplink_iface() or STA)
    else:
        for dev in UPLINK_CANDIDATES:
            _fwd_remove(dev)
        _fwd_pair(WG)


_hijack_on = False


def hijack_dns(enable):
    """Toggle catch-all DNS -> AP_IP so captive detection opens our page."""
    global _hijack_on
    if enable == _hijack_on:
        return
    if enable:
        with open(HIJACK_FILE, "w") as f:
            f.write("address=/#/%s\n" % AP_IP)
    else:
        try:
            os.remove(HIJACK_FILE)
        except FileNotFoundError:
            pass
    sh("systemctl", "reload", "dnsmasq") or sh("systemctl", "restart", "dnsmasq")
    _hijack_on = enable


# ------------------------------------------------------- background manager
def manager_loop():
    global _last_msg
    while True:
        try:
            st = upstream_state()
            if st == "online":
                set_route_mode("wg")
                hijack_dns(False)
            elif st == "portal":
                # upstream captive portal: give laptop direct upstream access
                set_route_mode("direct")
                hijack_dns(False)
            else:
                # no uplink: hijack DNS so our page pops on the laptop
                hijack_dns(True)
        except Exception as e:
            _last_msg = "manager error: %s" % e
        time.sleep(MANAGER_INTERVAL)


# ------------------------------------------------------------------- pages
PAGE = """<!doctype html>
<html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Pi Bridge — WiFi setup</title>
<style>
 body{font-family:system-ui,sans-serif;max-width:26em;margin:2em auto;padding:0 1em}
 .net{border:1px solid #ccc;border-radius:8px;padding:.6em;margin:.4em 0;
      display:flex;justify-content:space-between}
 label{display:block;cursor:pointer}
 input[type=password],input[type=text],select{width:100%;padding:.5em;
  margin:.5em 0;box-sizing:border-box}
 button{padding:.6em 1.2em;font-size:1em;width:100%}
 .msg{background:#eef;border-radius:8px;padding:.7em;margin:.8em 0}
 .ok{background:#e6ffe6}.warn{background:#fff3e0}
 .sig{color:#777;font-size:.85em}
</style></head><body>
<h2>Pi Bridge — WiFi setup</h2>
{% if cur %}<div class="msg ok">Connected to <b>{{cur}}</b> ({{state}})</div>
{% elif state %}<div class="msg warn">Upstream: {{state}}</div>{% endif %}
{% if wg=='connected' %}<div class="msg ok">VPN (wh0): connected</div>
{% else %}<div class="msg warn">VPN (wh0): {{wg}} — AP traffic has no tunnel exit</div>{% endif %}
{% if msg %}<div class="msg">{{msg}}</div>{% endif %}
{% if state=='portal' %}
 <div class="msg warn">This network needs a captive-portal login.
 Open <a href="http://neverssl.com">any web page</a> to sign in.</div>
{% endif %}
<h3>Available networks</h3>
<form method="post" action="/connect">
<select name="ssid">
{% for n in nets %}
 <option value="{{n.ssid}}">{{n.ssid}} — {{n.signal}} dBm {{'🔒' if n.secured else 'open'}}</option>
{% else %}
 <option value="" disabled selected>No networks found — type one below</option>
{% endfor %}
</select>
<input type="text" name="custom" placeholder="or type SSID (hidden network)">
<input type="password" name="password" placeholder="password (blank = open)">
<button type="submit">Connect</button>
</form>
<p><a href="/">rescan</a></p>
</body></html>"""


@app.route("/", defaults={"path": ""}, methods=["GET"])
@app.route("/<path:path>", methods=["GET"])
def index(path):
    # catch-all: captive-portal probes from the laptop land here too
    try:
        nets = scan_networks()
    except Exception:
        nets = []
    return render_template_string(
        PAGE, nets=nets, cur=sta_ssid(), msg=_last_msg,
        state=upstream_state(), wg=wg_state())


@app.route("/connect", methods=["POST"])
def connect():
    global _last_msg
    ssid = (request.form.get("custom") or request.form.get("ssid") or "").strip()
    password = request.form.get("password", "")
    if not ssid:
        return redirect("/")
    if password and not (8 <= len(password) <= 63):
        _last_msg = "Password must be 8-63 characters."
        return redirect("/")

    _last_msg = "Trying %s ..." % ssid
    existed = add_network(ssid, password)
    ok = try_connect()
    if ok:
        _last_msg = "Connected to %s — credentials saved." % ssid
    else:
        if not existed:
            remove_network(ssid)          # don't keep a dead profile
        sh("netplan", "apply")            # restore previous working config
        _last_msg = ("Could not connect to %s (wrong password? out of "
                     "range?). Previous settings restored." % ssid)
    return redirect("/")


@app.route("/status")
def status():
    return jsonify(ssid=sta_ssid(), channel=sta_channel(),
                   uplink=uplink_iface(), upstream=upstream_state(),
                   wg=wg_state())


if __name__ == "__main__":
    threading.Thread(target=manager_loop, daemon=True).start()
    app.run(host="0.0.0.0", port=PORT)
