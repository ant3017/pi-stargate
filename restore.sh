#!/bin/bash
# restore.sh — run ON THE PI.
# Restores every file under ./files/ to its absolute path (the tree
# mirrors /). Before overwriting a different existing file it saves a
# dated backup:  <dest>.bak-YYYYMMDD-HHMMSS
#
# Modes: taken from ./files.manifest (written by capture.sh), falling
# back to 755 for sbin/dispatcher scripts and 644 for everything else.
#
#   sudo bash restore.sh           # restore all tracked files
#   sudo bash restore.sh --dry-run # show what would change, write nothing
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/files"
MANIFEST="$HERE/files.manifest"
STAMP="$(date +%Y%m%d-%H%M%S)"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

[ -d "$SRC" ] || { echo "ERROR: $SRC not found" >&2; exit 1; }

mode_for() { # <relpath> -> mode on stdout
    local rel="$1" m
    m="$(awk -v r="$rel" '$1==r{print $2}' "$MANIFEST" 2>/dev/null | head -1)"
    if [ -n "$m" ]; then echo "$m"; return; fi
    case "$rel" in
        usr/local/sbin/*|etc/networkd-dispatcher/*) echo 755 ;;
        etc/netplan/*|etc/wireguard/*)              echo 600 ;;
        *)                                          echo 644 ;;
    esac
}

find "$SRC" -type f | sed "s|^$SRC/||" | while read -r rel; do
    dest="/$rel"
    mode="$(mode_for "$rel")"

    if [ -f "$dest" ] && cmp -s "$SRC/$rel" "$dest" 2>/dev/null; then
        echo "same     $dest"
        [ $DRY -eq 1 ] || sudo install -D -m "$mode" "$SRC/$rel" "$dest"  # normalize mode
        continue
    fi

    if [ -f "$dest" ]; then
        bak="${dest}.bak-${STAMP}"
        echo "backup   $dest -> $bak"
        [ $DRY -eq 1 ] || sudo cp -p "$dest" "$bak"
    else
        echo "new      $dest"
    fi

    echo "restore  $dest (mode $mode)"
    [ $DRY -eq 1 ] || sudo install -D -m "$mode" "$SRC/$rel" "$dest"
done

# if the snapshot says the dnsmasq resolvconf hook was disabled but a fresh
# package install put a live 'dnsmasq' hook back, move it out of the way again
if [ $DRY -eq 0 ] && [ -f "$SRC/etc/resolvconf/update.d/dnsmasq.disabled" ] \
        && [ -f /etc/resolvconf/update.d/dnsmasq ]; then
    sudo mv /etc/resolvconf/update.d/dnsmasq \
            /etc/resolvconf/update.d/dnsmasq.disabled
    echo "re-disabled dnsmasq resolvconf hook"
fi

if [ $DRY -eq 0 ]; then
    sudo systemctl daemon-reload
    echo "-----"
    echo "Restored. Restart affected services when ready, e.g.:"
    echo "  sudo netplan apply && sudo systemctl restart hostapd dnsmasq wg-quick@wh0 wifi-portal"
fi
