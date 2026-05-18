#!/bin/bash
# lock_hosts.sh — make /etc/hosts immutable using BSD chflags.
#
# After running this, /etc/hosts cannot be edited, appended to, or
# deleted by any user (including root)
#
# Run as: sudo ./lock_hosts.sh
#
# Reminder: take a backup *before* running this script. The guide
# tells you to do `sudo cp /etc/hosts /etc/hosts.backup` first.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must be run with sudo." >&2
    exit 1
fi

HOSTS=/etc/hosts

if [[ ! -f $HOSTS ]]; then
    echo "ERROR: $HOSTS does not exist on this system." >&2
    exit 1
fi

echo "==> Setting user immutable flag (uchg)..."
chflags uchg "$HOSTS"
echo "==> Setting system immutable flag (schg)..."
chflags schg "$HOSTS"

echo ""
echo "==> Verifying lock..."
ls -lO "$HOSTS" | sed 's/^/    /'

if echo "bypass test" >> "$HOSTS" 2>/dev/null; then
    echo "    ❌ LOCK FAILED — file is still writable!"
    exit 1
fi
echo "    ✓ Write blocked"

if rm -f "$HOSTS" 2>/dev/null; then
    echo "    ❌ LOCK FAILED — file was deleted!"
    exit 1
fi
echo "    ✓ Delete blocked"

echo ""
echo "================================================================"
echo "✓ /etc/hosts is now LOCKED."
echo ""
echo "  Flags:  schg + uchg"
echo "  Undo:   reboot into Recovery Mode and run"
echo "          chflags noschg /Volumes/Macintosh\\ HD/etc/hosts"
echo "================================================================"
