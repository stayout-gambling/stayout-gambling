#!/bin/bash
#
# /usr/local/sbin/dnsforce-keeper.sh
#
# Watches the main dnsforce LaunchDaemon. If anything unloads it via
# `launchctl bootout`, the keeper re-bootstraps it from the locked
# plist. Closes the one bypass gap that KeepAlive can't cover, because
# bootout removes a service from launchd's registry entirely — KeepAlive
# only respawns a process whose service is still loaded.
#
# Triggers (via the keeper LaunchDaemon):
#   * at boot (RunAtLoad)
#   * every 30 seconds (StartInterval)
#   * relaunched immediately on exit (KeepAlive, throttled to 30s)

set -u

LOG=/var/log/dnsforce.log
MAIN_LABEL=com.selfexclusion.dnsforce
MAIN_PLIST=/Library/LaunchDaemons/com.selfexclusion.dnsforce.plist

log() { printf '%s [keeper] %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

# Is the main daemon currently loaded into launchd?
if /bin/launchctl print "system/$MAIN_LABEL" >/dev/null 2>&1; then
    # Loaded — nothing to do. Don't log; this is the common case
    # and we don't want to spam the log every 30 seconds.
    exit 0
fi

# Not loaded — restore it.
log "main daemon not loaded; bootstrapping from $MAIN_PLIST"

if [[ ! -f "$MAIN_PLIST" ]]; then
    log "ERROR: $MAIN_PLIST missing — cannot bootstrap"
    exit 1
fi

# Re-enable in case the service was explicitly disabled.
# (Won't persist if disabled.plist is schg-locked — that's fine.)
/bin/launchctl enable "system/$MAIN_LABEL" 2>>"$LOG" || true

# Load the service back into launchd. This is the inverse of bootout.
if /bin/launchctl bootstrap system "$MAIN_PLIST" 2>>"$LOG"; then
    log "main daemon re-bootstrapped successfully"
else
    log "ERROR: bootstrap failed"
    exit 1
fi

exit 0
