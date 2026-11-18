
# stargate tunnel


# The System
cat /etc/os-release
```
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
NAME="Debian GNU/Linux"
VERSION_ID="12"
VERSION="12 (bookworm)"
VERSION_CODENAME=bookworm
ID=debian
HOME_URL="https://www.debian.org/"
SUPPORT_URL="https://www.debian.org/support"
BUG_REPORT_URL="https://bugs.debian.org/"
```

lsb_release -a
```
No LSB modules are available.
Distributor ID: Debian
Description:    Debian GNU/Linux 12 (bookworm)
Release:        12
Codename:       bookworm
```

uname -a
```
Linux stargate 6.12.115+rpt-rpi-v8 #1 SMP PREEMPT Debian 1:6.12.115-1+rpt1 (2026-11-03) aarch64 GNU/Linux
```

cat /etc/rpi-issue
```
Raspberry Pi reference 2024-11-19
Generated using pi-gen, https://github.com/RPi-Distro/pi-gen, 891df1e21ed2b6099a2e6a13e26c91dea44b34d4, stage2
```

## connection
the raspberry is reachable via
```
ssh antonio@192.168.255.3
```


## config files

the settings of the raspberry are reflected in the files in this repository

## target behaviour

### uplink
the raspberry connects to the internet via eth0 or wifi uplink(wlan0)

### downlink
he raspberry creates an ap0 interface for a laptop to connect to it (downlink).

this allows the laptop to connect to the internet via the raspberry. 

## wifi channels sync
there is a service and timer to check that uplink and downlink wifi have same channel and country code (watch-ap-channel). this is a raspberry limitation: in order to use the same wifi card for uplink and downlink concurrently it is necessary to use 2.4 ghz band and same channel and country code in uplink and downlink

## wireguard

the raspberry tunnels all data form the laptop through a wireguard interface (wh0)

## SSID selection (ap0 portal)

the raspberry creates a portal login page where the user connectd to ap0 can elect the uplink SSID to connect to . the details entered are saved for future use

## save and restore configs
the files capture.sh and restore.sh are useful to copy the relevant files from the raspberry to this repository and vice versa
