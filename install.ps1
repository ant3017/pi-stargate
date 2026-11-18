# ============================================================
# Deploy the Pi bridge config to the Pi over SSH.
# Run on Windows:  powershell -File .\install.ps1
# Prereqs: OpenSSH client (built into Win10+), sudo on the Pi.
# ============================================================

# ------------- EDIT THESE BEFORE RUNNING ----------------------

# SSH target. wh0 IP only works while the tunnel is up;
# use 192.168.50.1 when connected to the Pi's own AP instead.
$Server          = "antonio@192.168.255.3"

# --- AP (ap0): the network your laptop joins ---
$ApSsid          = "sg0"
$ApPassword      = "litfiba25!"            # WPA2, 8-63 chars

# --- Uplink STA (wlan0): first router to connect to ---
# Can also be added/changed later via the portal page.
$RouterSsid      = "YourRouterSSID"
$RouterPassword  = "your-router-password"

# --- WireGuard (wh0) ---
$WgPrivateKey    = "PI-PRIVATE-KEY-HERE"     # this Pi's private key
$WgAddress       = "192.168.255.3/24"
$WgPeerPublicKey = "SERVER-PUBLIC-KEY-HERE"
$WgEndpoint      = "server.example.com:51820"
$WgAllowedIps    = "0.0.0.0/0"
$WgKeepalive     = 25

# -------------------------------------------------------------

$ErrorActionPreference = "Stop"
$Bundle = "$PSScriptRoot\files"
$Portal = "$PSScriptRoot\pi-portal"
$Stage  = "$env:TEMP\pi-config-files"

# ---- sanity checks --------------------------------------------
if (-not (Test-Path "$Bundle\etc"))                { throw "bundle not found: $Bundle" }
if (-not (Test-Path "$Portal\wifi_portal.py"))     { throw "portal not found: $Portal\wifi_portal.py" }
if ($ApPassword.Length -lt 8 -or $ApPassword.Length -gt 63) {
    throw "ApPassword must be 8-63 characters (WPA2 requirement)"
}
foreach ($v in 'WgPrivateKey','WgPeerPublicKey') {
    if ((Get-Variable $v).Value -match 'HERE') {
        Write-Warning "$v still contains a placeholder - WireGuard will not connect until a real key is set."
    }
}

# ---- stage a filled copy (never touches files/ templates) -----
Write-Host "Staging..."
if (Test-Path $Stage) { Remove-Item -Recurse -Force $Stage }
Copy-Item -Recurse $Bundle $Stage
Copy-Item "$Portal\wifi_portal.py" "$Stage\usr\local\sbin\wifi_portal.py"

$subs = @{
    "$Stage\etc\hostapd\hostapd.conf" = @{
        'ssid=PiBridge'                  = "ssid=$ApSsid"
        'wpa_passphrase=YourAPPassword'  = "wpa_passphrase=$ApPassword"
    }
    "$Stage\etc\netplan\60-wifi.yaml" = @{
        'YourRouterSSID'       = $RouterSsid
        'your-router-password' = $RouterPassword
    }
    "$Stage\etc\wireguard\wh0.conf" = @{
        '<PI-PRIVATE-KEY>'          = $WgPrivateKey
        '<SERVER-PUBLIC-KEY>'       = $WgPeerPublicKey
        '<SERVER-IP-OR-HOST>:51820' = $WgEndpoint
        '192.168.255.3/24'          = $WgAddress
        'AllowedIPs = 0.0.0.0/0'    = "AllowedIPs = $WgAllowedIps"
        'PersistentKeepalive = 25'  = "PersistentKeepalive = $WgKeepalive"
    }
}
foreach ($file in $subs.Keys) {
    $text = Get-Content $file -Raw
    foreach ($find in $subs[$file].Keys) {
        $text = $text.Replace($find, $subs[$file][$find])
    }
    Set-Content -Path $file -Value $text -NoNewline -Encoding ASCII
}

# ---- upload ----------------------------------------------------
Write-Host "Uploading config tree to ${Server}..."
scp -r "$Stage" "${Server}:/tmp/pi-config-files"
if ($LASTEXITCODE -ne 0) { throw "scp config tree failed" }

Write-Host "Uploading installer..."
scp "$PSScriptRoot\install.sh" "${Server}:/tmp/pi-config-install.sh"
if ($LASTEXITCODE -ne 0) { throw "scp install.sh failed" }

# ---- run --------------------------------------------------------
Write-Host "Running installer on the Pi (sudo will prompt)..."
ssh -t $Server "bash /tmp/pi-config-install.sh"

Write-Host "Done. On the Pi check: iw dev, systemctl status hostapd, wg show"
