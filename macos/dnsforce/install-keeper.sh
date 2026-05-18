#!/bin/bash
#
# install-keeper.sh — installs the watchdog daemon and locks its files.
#
# Run AFTER install.sh + lock.sh have already been run on the main stack.
# This adds a second daemon that detects when the main one has been
# booted out and re-bootstraps it.
#
# After this runs:
#   - sober-you would need TWO bootouts within 30 seconds AND a pfctl -d
#     to fully bypass — currently the simplest sober-bypass path
#   - any reboot restores everything (plists are locked)
#
# Run with sudo.

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
SBIN_DIR=/usr/local/sbin
LAUNCHD_DIR=/Library/LaunchDaemons

KEEPER_SH="$SBIN_DIR/dnsforce-keeper.sh"
KEEPER_PLIST="$LAUNCHD_DIR/com.selfexclusion.dnsforce-keeper.plist"

# ---- root check ----
if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: run with sudo." >&2
    exit 1
fi

# ---- source files check ----
for f in dnsforce-keeper.sh com.selfexclusion.dnsforce-keeper.plist; do
    [[ -f "$SRC/$f" ]] || { echo "ERROR: missing $SRC/$f"; exit 1; }
done

# ---- sanity: main daemon should already be installed ----
if [[ ! -f "$LAUNCHD_DIR/com.selfexclusion.dnsforce.plist" ]]; then
    echo "ERROR: main daemon plist not found at $LAUNCHD_DIR/com.selfexclusion.dnsforce.plist"
    echo "       Run install.sh first."
    exit 1
fi

echo "Will install + lock:"
echo "  $KEEPER_SH"
echo "  $KEEPER_PLIST"
echo ""
read -r -p "Proceed? [y/N] " ans
case "$ans" in
    [yY]|[yY][eE][sS]) : ;;
    *) echo "Aborted."; exit 0 ;;
esac

# ---- install files ----
echo ">> Installing keeper script..."
install -m 755 -o root -g wheel "$SRC/dnsforce-keeper.sh" "$KEEPER_SH"

echo ">> Installing keeper LaunchDaemon..."
install -m 644 -o root -g wheel "$SRC/com.selfexclusion.dnsforce-keeper.plist" "$KEEPER_PLIST"

# ---- load keeper daemon ----
echo ">> Loading keeper daemon..."
launchctl bootout system "$KEEPER_PLIST" 2>/dev/null || true
launchctl bootstrap system "$KEEPER_PLIST"
launchctl enable system/com.selfexclusion.dnsforce-keeper

# ---- lock both files ----
echo ">> Locking keeper files (chflags schg)..."
chflags schg "$KEEPER_SH"
chflags schg "$KEEPER_PLIST"

# ---- verify ----
echo ""
echo "==============================================="
echo " Verifying..."
echo "==============================================="

echo ""
echo "Keeper daemon:"
launchctl print system/com.selfexclusion.dnsforce-keeper 2>/dev/null \
    | grep -E "state|last exit code" | sed 's/^/  /' || echo "  not loaded"

echo ""
echo "Lock status:"
for f in "$KEEPER_SH" "$KEEPER_PLIST"; do
    if stat -f '%Sf' "$f" | grep -q 'schg'; then
        echo "  [OK]   $f"
    else
        echo "  [FAIL] $f"
    fi
done

echo ""
echo "==============================================="
echo " Done."
echo "==============================================="
echo ""
echo "Test the new protection:"
echo "  sudo launchctl bootout system/com.selfexclusion.dnsforce"
echo "  sleep 35"
echo "  sudo launchctl print system/com.selfexclusion.dnsforce | grep state"
echo "  # Should show 'state = running' — keeper re-bootstrapped it"
echo ""
echo "Live log:  tail -f /var/log/dnsforce.log"
echo "  You'll see '[keeper] main daemon not loaded; bootstrapping ...'"
echo "  followed by the main daemon's normal sync activity."
