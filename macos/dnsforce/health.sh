#!/bin/bash
# health.sh — quick diagnostic for dnsforce.
#
# Run as:  sudo ./health.sh
#
# Useful when something feels off and you want to confirm the daemons
# are running, the sync script is executable, and the log shows recent
# activity. Read-only; does not change state.

echo "=== 1. Is the sync script runnable? ==="
ls -la /usr/local/sbin/dnsforce-sync.sh
sudo /usr/local/sbin/dnsforce-sync.sh; echo "exit code: $?"

echo ""
echo "=== 2. Log activity ==="
ls -la /var/log/dnsforce.log
tail -30 /var/log/dnsforce.log

echo ""
echo "=== 3. Full main-daemon state ==="
sudo launchctl print system/com.selfexclusion.dnsforce | head -50

echo ""
echo "=== 4. Keeper-daemon state (for comparison) ==="
sudo launchctl print system/com.selfexclusion.dnsforce-keeper | grep -E "state|last exit code|path ="

echo ""
echo "=== 5. launchd's view of recent activity ==="
sudo log show --predicate 'subsystem == "com.apple.xpc.launchd"' --info --last 5m 2>/dev/null \
    | grep -i "selfexclusion\|dnsforce" | tail -20
