#!/bin/bash
#
# lock.sh — apply system-immutable (schg) flag to all dnsforce files.
#
# After running this:
#   - No file in the list can be modified, deleted, or replaced
#     by ANY user including root.
#   - This is the same protection you applied to /etc/hosts.
#
# What's still possible via runtime commands (sudo):
#   - `launchctl bootout`, `launchctl kill`     — daemon relaunches (KeepAlive)
#   - `pfctl -d` / `pfctl -F all`               — sync.sh self-heals within 60s
#   - `launchctl disable system/...`            — see lock.sh notes below
#
# The intent is to make undoing dnsforce require deliberate effort
# from a sober state (Recovery Mode boot), the same threshold you
# already chose for /etc/hosts.
#
# Run with sudo.

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: run with sudo." >&2
    exit 1
fi

# Files that make up dnsforce — every one of them must exist and stay put.
FILES=(
    /usr/local/etc/dnsforce/dnsforce.pf.conf
    /usr/local/etc/dnsforce/com.selfexclusion.dnsforce
    /usr/local/etc/dnsforce/doh-endpoints.list
    /usr/local/sbin/dnsforce-sync.sh
    /Library/LaunchDaemons/com.selfexclusion.dnsforce.plist
)

# launchd's per-service disable state file. If this is locked while
# the service is enabled, `launchctl disable` can't persist the
# disable across reboots, and the daemon comes back on next boot.
LAUNCHD_DISABLED_PLIST=/var/db/com.apple.xpc.launchd/disabled.plist

echo "About to lock the following files with chflags schg:"
for f in "${FILES[@]}"; do
    if [[ -f "$f" ]]; then
        echo "  $f"
    else
        echo "  $f  [MISSING — run install.sh first]"
        exit 1
    fi
done
echo ""
echo "After locking, undoing dnsforce requires booting into Recovery"
echo "Mode (Apple Silicon: hold power button at startup; Intel:"
echo "Cmd-R) and running 'chflags noschg' on each file from there."
echo ""
echo "Make a clear-headed decision now. There is no convenient undo."
echo ""
read -r -p "Lock now? [y/N] " ans
case "$ans" in
    [yY]|[yY][eE][sS]) : ;;
    *) echo "Aborted."; exit 0 ;;
esac

# Ensure the LaunchDaemon is currently enabled before we lock,
# so the locked state reflects "service enabled."
launchctl enable system/com.selfexclusion.dnsforce 2>/dev/null || true

# Make sure the disabled.plist exists (touch creates it empty if missing),
# then lock it so launchctl disable can't persist a "disabled" flag.
if [[ ! -f "$LAUNCHD_DISABLED_PLIST" ]]; then
    /usr/bin/touch "$LAUNCHD_DISABLED_PLIST"
fi

echo ""
echo ">> Locking files..."
for f in "${FILES[@]}"; do
    /usr/bin/chflags schg "$f"
    echo "  schg  $f"
done

echo ""
echo ">> Locking launchd disabled-state file..."
/usr/bin/chflags schg "$LAUNCHD_DISABLED_PLIST"
echo "  schg  $LAUNCHD_DISABLED_PLIST"

echo ""
echo ">> Verifying flags..."
ALL_LOCKED=1
for f in "${FILES[@]}" "$LAUNCHD_DISABLED_PLIST"; do
    if /usr/bin/stat -f '%Sf' "$f" | grep -q 'schg'; then
        echo "  [OK]   $f"
    else
        echo "  [FAIL] $f"
        ALL_LOCKED=0
    fi
done

if [[ "$ALL_LOCKED" -eq 1 ]]; then
    echo ""
    echo "All dnsforce files locked. Stack is now immutable from running OS."
    echo ""
    echo "Reminder of how to undo (only do this from a clear-headed state):"
    echo "  1. Reboot into Recovery Mode"
    echo "     - Apple Silicon: hold power button at startup"
    echo "     - Intel: Cmd-R at startup"
    echo "  2. Open Terminal from Utilities menu"
    echo "  3. Run for each file:"
    echo "       chflags noschg /path/to/file"
    echo "  4. Reboot normally and edit/remove as needed."
else
    echo ""
    echo "ERROR: some files could not be locked. Check ownership/permissions."
    exit 1
fi
