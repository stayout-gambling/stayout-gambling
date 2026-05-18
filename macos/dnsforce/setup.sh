#!/bin/bash
#
# setup.sh — full one-shot deployment of dnsforce.
#
# Does, in order:
#   1. install.sh       — main daemon (sync + PF rules)
#   2. install-keeper.sh — watchdog daemon
#   3. lock.sh          — chflags schg on every file
#
# Asks for confirmation once at the start, then runs all three
# non-interactively.
#
# Run with sudo.

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"

# ---- root check ----
if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: run with sudo." >&2
    exit 1
fi

# ---- check all required scripts are present ----
for f in install.sh install-keeper.sh lock.sh; do
    [[ -f "$SRC/$f" ]] || { echo "ERROR: missing $SRC/$f"; exit 1; }
done

cat <<'EOF'
================================================================
  dnsforce — full setup
================================================================

This will run, in order:

  1. install.sh        Deploy main daemon (PF rules + DNS sync)
  2. install-keeper.sh Deploy watchdog (resurrects main if killed)
  3. lock.sh           chflags schg on every dnsforce file

After this finishes, the stack is immutable until Recovery Mode.

You will be asked to confirm ONCE here. Each sub-script's own
confirmation prompt is bypassed automatically.

================================================================
EOF

read -r -p "Proceed with full setup + lock? [y/N] " ans
case "$ans" in
    [yY]|[yY][eE][sS]) : ;;
    *) echo "Aborted."; exit 0 ;;
esac

# Sub-scripts each have a 'read -r -p "...? [y/N]"' confirmation.
# We feed 'y\n' into each one's stdin to auto-confirm.
AUTO_YES=$'y\n'

echo ""
echo "================================================================"
echo "  Step 1/3 : install.sh"
echo "================================================================"
printf '%s' "$AUTO_YES" | bash "$SRC/install.sh"

echo ""
echo "================================================================"
echo "  Step 2/3 : install-keeper.sh"
echo "================================================================"
printf '%s' "$AUTO_YES" | bash "$SRC/install-keeper.sh"

echo ""
echo "================================================================"
echo "  Step 3/3 : lock.sh"
echo "================================================================"
printf '%s' "$AUTO_YES" | bash "$SRC/lock.sh"

echo ""
echo "================================================================"
echo "  All done."
echo "================================================================"
echo ""
echo "Confirm everything is running:"
echo "  sudo launchctl print system/com.selfexclusion.dnsforce        | grep state"
echo "  sudo launchctl print system/com.selfexclusion.dnsforce-keeper | grep state"
echo "  tail -f /var/log/dnsforce.log"
echo ""
echo "Test the keeper closes the bootout gap:"
echo "  sudo launchctl bootout system/com.selfexclusion.dnsforce"
echo "  sleep 35"
echo "  sudo launchctl print system/com.selfexclusion.dnsforce | grep state"
echo "  # Expect: state = running  (keeper resurrected it)"
echo ""
