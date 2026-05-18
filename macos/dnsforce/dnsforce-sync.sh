#!/bin/bash
#
# /usr/local/sbin/dnsforce-sync.sh
#
# Self-healing PF maintainer + DNS sync. Run by LaunchDaemon:
#   * at boot (RunAtLoad)
#   * on every network change (WatchPaths on resolv.conf)
#   * every 60s (StartInterval watchdog)
#
# Responsibilities:
#   1. Ensure PF is enabled.
#   2. Ensure our main PF ruleset is loaded (the one that includes
#      our anchor reference). If anything flushed PF or reloaded
#      /etc/pf.conf, we restore our ruleset.
#   3. Ensure our anchor's rules + doh_endpoints table are loaded.
#   4. Sync <allowed_dns> with current system resolvers so DNS
#      keeps working across WiFi/cellular/VPN/captive-portal switches.
#
# No system files in /etc/ are modified — everything lives under
# /usr/local/etc/dnsforce/ and /usr/local/sbin/.

set -u

LOG=/var/log/dnsforce.log
ANCHOR=com.selfexclusion.dnsforce
ANCHOR_FILE=/usr/local/etc/dnsforce/com.selfexclusion.dnsforce
PFCONF=/usr/local/etc/dnsforce/dnsforce.pf.conf

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

# --------------------------------------------------------------------
# 1. Ensure PF is enabled AND our main ruleset is the active one.
#    `pfctl -s rules` shows the loaded main ruleset; if our anchor
#    name doesn't appear, something else reloaded PF and we need to
#    reload our config.
# --------------------------------------------------------------------
PF_ENABLED=$(/sbin/pfctl -s info 2>/dev/null | awk '/^Status:/ {print $2}')
HAVE_OUR_ANCHOR=$(/sbin/pfctl -s rules 2>/dev/null | grep -c "$ANCHOR" || true)

if [[ "$PF_ENABLED" != "Enabled" ]] || [[ "$HAVE_OUR_ANCHOR" -eq 0 ]]; then
    if /sbin/pfctl -E -f "$PFCONF" >>"$LOG" 2>&1; then
        log "loaded main ruleset from $PFCONF"
    else
        log "ERROR loading $PFCONF — aborting"
        exit 1
    fi
fi

# --------------------------------------------------------------------
# 2. Ensure our anchor has its rules loaded. The anchor reference
#    is in the main ruleset (loaded above), but the anchor's rules
#    themselves can be empty if something flushed the anchor.
# --------------------------------------------------------------------
if ! /sbin/pfctl -a "$ANCHOR" -s rules 2>/dev/null | grep -q doh_endpoints; then
    if /sbin/pfctl -a "$ANCHOR" -f "$ANCHOR_FILE" >>"$LOG" 2>&1; then
        log "loaded anchor rules from $ANCHOR_FILE"
    else
        log "ERROR loading $ANCHOR_FILE"
        exit 1
    fi
fi

# --------------------------------------------------------------------
# 3. Query the system for current resolvers.
#    scutil --dns reflects WiFi DHCP DNS, cellular APN DNS,
#    VPN-pushed DNS, manual overrides — everything.
# --------------------------------------------------------------------
DNS=$(/usr/sbin/scutil --dns 2>/dev/null \
    | awk '/nameserver\[[0-9]+\]/ {print $3}' \
    | grep -Ev '^(127\.|::1$|fe80:)' \
    | sort -u)

# --------------------------------------------------------------------
# 4. Fail-safe: if we can't see any resolvers (e.g., during boot or
#    a fast network handover), keep the existing table. Stale entries
#    are better than blackholing DNS.
# --------------------------------------------------------------------
if [[ -z "$DNS" ]]; then
    log "skip: scutil returned no resolvers (network down or transitioning)"
    exit 0
fi

# --------------------------------------------------------------------
# 5. Compare current table to desired; only update + log on change.
# --------------------------------------------------------------------
CURRENT=$(/sbin/pfctl -a "$ANCHOR" -t allowed_dns -T show 2>/dev/null | sort -u)
DESIRED=$(printf '%s\n' $DNS | sort -u)

if [[ "$CURRENT" != "$DESIRED" ]]; then
    # shellcheck disable=SC2086
    /sbin/pfctl -a "$ANCHOR" -t allowed_dns -T replace $DNS >>"$LOG" 2>&1
    log "updated allowed_dns -> $(echo $DNS | tr '\n' ' ')"
fi

exit 0
