#!/bin/bash
#
# install.sh — installs the DNS-force layer without touching any
# system files in /etc/. Everything lives in /usr/local/ and
# /Library/LaunchDaemons/.
#
# Files created:
#   /usr/local/etc/dnsforce/dnsforce.pf.conf         (PF main ruleset)
#   /usr/local/etc/dnsforce/com.selfexclusion.dnsforce (anchor rules)
#   /usr/local/sbin/dnsforce-sync.sh                 (sync daemon)
#   /Library/LaunchDaemons/com.selfexclusion.dnsforce.plist
#
# Files NOT touched:
#   /etc/hosts        (you've locked this — your existing entries stay)
#   /etc/pf.conf      (untouched; we load our own ruleset)
#   /etc/pf.anchors/  (untouched)
#
# Run with sudo.

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
ETC_DIR=/usr/local/etc/dnsforce
SBIN_DIR=/usr/local/sbin
LAUNCHD_DIR=/Library/LaunchDaemons

# ---- root check ----
if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: run with sudo." >&2
    exit 1
fi

# ---- macOS sanity check ----
if [[ "$(uname)" != "Darwin" ]]; then
    echo "ERROR: macOS only."; exit 1
fi

# ---- source files check ----
for f in dnsforce.pf.conf \
         com.selfexclusion.dnsforce \
         doh-endpoints.list \
         dnsforce-sync.sh \
         com.selfexclusion.dnsforce.plist; do
    [[ -f "$SRC/$f" ]] || { echo "ERROR: missing $SRC/$f"; exit 1; }
done

# ---- show plan ----
echo "Current system DNS (will be auto-tracked):"
/usr/sbin/scutil --dns | awk '/nameserver\[[0-9]+\]/ {print "  "$3}' | sort -u || true
echo ""
echo "Will install:"
echo "  $ETC_DIR/dnsforce.pf.conf"
echo "  $ETC_DIR/com.selfexclusion.dnsforce"
echo "  $ETC_DIR/doh-endpoints.list"
echo "  $SBIN_DIR/dnsforce-sync.sh"
echo "  $LAUNCHD_DIR/com.selfexclusion.dnsforce.plist"
echo ""
echo "Will NOT modify: /etc/hosts, /etc/pf.conf, /etc/pf.anchors/"
echo ""
read -r -p "Proceed? [y/N] " ans
case "$ans" in
    [yY]|[yY][eE][sS]) : ;;
    *) echo "Aborted."; exit 0 ;;
esac

# ---- create dirs ----
mkdir -p "$ETC_DIR" "$SBIN_DIR"

# ---- snapshot current PF state for rollback reference ----
SNAP="$ETC_DIR/pre-install-pf-state.$(date +%s).txt"
{
    echo "=== pfctl -s info ==="
    /sbin/pfctl -s info 2>&1 || true
    echo ""
    echo "=== pfctl -s rules ==="
    /sbin/pfctl -s rules 2>&1 || true
    echo ""
    echo "=== /etc/pf.conf ==="
    cat /etc/pf.conf 2>/dev/null || true
} > "$SNAP"
chmod 644 "$SNAP"
echo ">> Snapshotted pre-install PF state to $SNAP"

# ---- install files ----
echo ">> Installing PF main ruleset..."
install -m 644 -o root -g wheel "$SRC/dnsforce.pf.conf" "$ETC_DIR/dnsforce.pf.conf"

echo ">> Installing PF anchor..."
install -m 644 -o root -g wheel "$SRC/com.selfexclusion.dnsforce" "$ETC_DIR/com.selfexclusion.dnsforce"

echo ">> Installing DoH endpoints list..."
install -m 644 -o root -g wheel "$SRC/doh-endpoints.list" "$ETC_DIR/doh-endpoints.list"

echo ">> Installing sync script..."
install -m 755 -o root -g wheel "$SRC/dnsforce-sync.sh" "$SBIN_DIR/dnsforce-sync.sh"

echo ">> Installing LaunchDaemon..."
install -m 644 -o root -g wheel "$SRC/com.selfexclusion.dnsforce.plist" "$LAUNCHD_DIR/com.selfexclusion.dnsforce.plist"

# ---- load LaunchDaemon ----
launchctl bootout system "$LAUNCHD_DIR/com.selfexclusion.dnsforce.plist" 2>/dev/null || true
launchctl bootstrap system "$LAUNCHD_DIR/com.selfexclusion.dnsforce.plist"
launchctl enable system/com.selfexclusion.dnsforce

# ---- run first sync explicitly so allowed_dns is populated NOW ----
echo ">> Running first sync (loading PF + populating allowed_dns)..."
"$SBIN_DIR/dnsforce-sync.sh"

# ---- flush DNS cache (your existing /etc/hosts re-read; we didn't change it) ----
echo ">> Flushing DNS cache..."
dscacheutil -flushcache 2>/dev/null || true
killall -HUP mDNSResponder 2>/dev/null || true

# ============================================================
#  Verify
# ============================================================
echo ""
echo "==============================================="
echo " Verifying..."
echo "==============================================="

echo "PF Status: $(/sbin/pfctl -s info 2>/dev/null | awk '/^Status:/ {print $2}')"

echo ""
echo "Active main ruleset (looking for our anchor):"
if /sbin/pfctl -s rules 2>/dev/null | grep -q com.selfexclusion.dnsforce; then
    echo "  [OK] our anchor is in the main ruleset"
else
    echo "  [FAIL] our anchor is NOT in the main ruleset"
fi

echo ""
echo "Allowed DNS (auto-populated from system):"
/sbin/pfctl -a com.selfexclusion.dnsforce -t allowed_dns -T show 2>/dev/null | sed 's/^/  /' \
    || echo "  (none — first sync failed?)"

echo ""
echo "Anchor rule count:"
/sbin/pfctl -a com.selfexclusion.dnsforce -s rules 2>/dev/null | wc -l | awk '{print "  "$1" rules"}'

echo ""
echo "LaunchDaemon state:"
launchctl print system/com.selfexclusion.dnsforce 2>/dev/null \
    | grep -E "state|last exit code" | sed 's/^/  /' || echo "  not loaded"

# ---- functional sanity ----
echo ""
echo "Functional check:"
if /usr/bin/dig +short +time=3 +tries=1 example.com A >/dev/null 2>&1; then
    echo "  [OK] DNS resolution works (example.com resolved)"
else
    echo "  [WARN] example.com did NOT resolve."
    echo "         Try: sudo $SBIN_DIR/dnsforce-sync.sh"
fi

if /sbin/ping -c 1 -t 3 1.1.1.1 >/dev/null 2>&1; then
    echo "  [OK] Outbound IP connectivity works"
else
    echo "  [WARN] Cannot reach 1.1.1.1 — check your network."
fi

echo ""
echo "==============================================="
echo " Done."
echo "==============================================="
echo ""
echo "DNS allowlist auto-updates when you switch networks."
echo "Your existing /etc/hosts (locked) is untouched and still authoritative."
echo ""
echo "Sanity tests:"
echo "  1) Plain DNS to a non-system resolver (should TIMEOUT):"
echo "       dig @8.8.8.8 example.com +time=3 +tries=1"
echo "  2) DoH to Cloudflare (should FAIL):"
echo "       curl -m 5 'https://1.1.1.1/dns-query?name=example.com' \\"
echo "            -H 'accept: application/dns-json'"
echo "  3) Test a name you've blocked in /etc/hosts (should resolve to your block IP)"
echo ""
echo "Live sync log:"
echo "       tail -f /var/log/dnsforce.log"
