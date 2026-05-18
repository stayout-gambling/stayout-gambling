# dnsforce — DNS firewall + auto-healing watchdog for macOS

## What this does

This is a kernel-level DNS firewall that closes the most common bypass routes
around content blocking:

1. **Blocks DNS-over-HTTPS (DoH)** to a comprehensive list of public providers
   (Cloudflare, Google, Quad9, AdGuard, NextDNS, Mullvad, ControlD, OpenDNS,
   and ~10 more). When a browser like Chrome or Firefox has DoH enabled, it
   ignores `/etc/hosts` entirely and resolves names via its own encrypted
   channel to one of these providers — neatly bypassing every other layer
   of this setup. `dnsforce` drops those packets at the kernel.

2. **Blocks DNS-over-TLS (DoT)** on TCP/853 and DNS-over-QUIC on UDP/8853.

3. **Allows plain DNS (port 53) only to your current system resolvers.**
   The list of allowed resolvers is auto-maintained — when you switch
   from home Wi-Fi to cellular to a captive portal at the airport, the
   list updates within seconds so DNS keeps working without you doing
   anything.

4. **Self-heals.** If anything tries to flush the firewall rules with
   `pfctl -F all` or unload the daemon with `launchctl bootout`, the
   rules come back within 30 seconds. There's a watchdog watching the
   watchdog.

5. **Cannot be uninstalled from a running OS.** Every file is locked
   with the system-immutable flag (`schg`). To undo, you have to reboot
   into Recovery Mode and explicitly remove the flag. This is the same
   threshold of difficulty as `/etc/hosts` locked the same way.

## How to install

```bash
cd dnsforce
sudo ./setup.sh
```

This runs three sub-scripts in order:

| Script               | What it does                                              |
| -------------------- | --------------------------------------------------------- |
| `install.sh`         | Deploys the main daemon (PF rules + DNS sync)             |
| `install-keeper.sh`  | Deploys the watchdog (resurrects the main daemon if killed)|
| `lock.sh`            | Applies `chflags schg` to every file in the stack         |

After `setup.sh` finishes, nothing in `/etc/` has been modified. Everything
lives under `/usr/local/etc/dnsforce/`, `/usr/local/sbin/`, and
`/Library/LaunchDaemons/`. Your existing `/etc/hosts` (if you've already
locked it) is left completely alone.

## Verifying it works

```bash
# Plain DNS to a non-system resolver — should TIMEOUT
dig @8.8.8.8 example.com +time=3 +tries=1

# DoH to Cloudflare — should FAIL
curl -m 5 'https://1.1.1.1/dns-query?name=example.com' \
     -H 'accept: application/dns-json'

# Live sync log
tail -f /var/log/dnsforce.log
```

## How to undo (only in a clear-headed state)

1. Reboot into Recovery Mode
   - **Apple Silicon**: hold the power button at startup
   - **Intel**: hold ⌘R at startup
2. Open Terminal from Utilities menu
3. Remove the immutable flag from each file:
   ```
   chflags noschg /usr/local/etc/dnsforce/dnsforce.pf.conf
   chflags noschg /usr/local/etc/dnsforce/com.selfexclusion.dnsforce
   chflags noschg /usr/local/etc/dnsforce/doh-endpoints.list
   chflags noschg /usr/local/sbin/dnsforce-sync.sh
   chflags noschg /usr/local/sbin/dnsforce-keeper.sh
   chflags noschg /Library/LaunchDaemons/com.selfexclusion.dnsforce.plist
   chflags noschg /Library/LaunchDaemons/com.selfexclusion.dnsforce-keeper.plist
   chflags noschg /var/db/com.apple.xpc.launchd/disabled.plist
   ```
4. Reboot normally and delete/disable as needed.

This is intentionally inconvenient. If you find yourself running these
commands during an urge, please stop and call a support line first.

## Notes about captive portals

Public Wi-Fi (airports, hotels, cafes, airplanes) often uses a captive
portal — a webpage you have to authenticate against before getting full
internet. These work fine with `dnsforce` *most* of the time, because:

- The captive portal usually advertises its own DNS server via DHCP,
  which gets added to your system resolvers automatically.
- `dnsforce` then allows DNS to that resolver.

If a captive portal is hostile to this setup (rare), the symptom is that
DNS for the portal's login page won't resolve. The fix:

1. Open System Settings → Network → your active Wi-Fi → Details → DNS.
2. Remove `1.1.1.1` if you see it listed manually (this can happen if
   you previously configured it). System-pushed DNS will then be used.
3. Reconnect to the network.

## Files in this folder

| File                                          | Role                                                  |
| --------------------------------------------- | ----------------------------------------------------- |
| `setup.sh`                                    | One-shot: runs install + install-keeper + lock        |
| `install.sh`                                  | Deploys the main daemon                               |
| `install-keeper.sh`                           | Deploys the watchdog daemon                           |
| `lock.sh`                                     | Makes every file in the stack immutable               |
| `health.sh`                                   | Read-only diagnostic. Run with `sudo` if anything feels off |
| `dnsforce-sync.sh`                            | The actual sync logic (PF + DNS allowlist)            |
| `dnsforce-keeper.sh`                          | The watchdog that resurrects the main daemon          |
| `dnsforce.pf.conf`                            | PF main ruleset (mirrors Apple defaults + our anchor) |
| `com.selfexclusion.dnsforce`                  | PF anchor rules (the actual filtering)                |
| `doh-endpoints.list`                          | List of public DoH IPs to block                       |
| `com.selfexclusion.dnsforce.plist`            | LaunchDaemon for the main daemon                      |
| `com.selfexclusion.dnsforce-keeper.plist`     | LaunchDaemon for the watchdog                         |
