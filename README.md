# stayout-gambling

A defense-in-depth setup for blocking gambling sites and apps on your own devices, designed by someone who needed it and is releasing it anonymously so other people don't have to figure it out alone.

## [Start here](https://stayout-gambling.github.io/stayout-gambling/guide.html)

**Open `guide.html` in any web browser.** That's the entire setup walkthrough, from sign-up to lockdown, written for both non-technical users and software engineers. About a 30-minute read; about 3 hours to actually execute.

## What's in this repository

```
.
├── guide.html                                  ← Open this first
├── LICENSE                                     MIT (full text)
│
├── cloudflare/
│   ├── migrate_to_lists.py                     Bulk-create 63 CF Gateway Lists + DNS rule
│   └── apex_only.txt                           62,636 gambling apex domains
│
├── macos/
│   ├── hosts                                   4.4 MB sinkhole hosts file (gambling domains → 0.0.0.0)
│   ├── lock_hosts.sh                           Apply chflags schg+uchg to /etc/hosts
│   ├── disable-doh-and-proxy.mobileconfig      Disables DoH + locks proxy in 33 browsers; has
│   │                                           an empty removal-password field for you to fill in
│   └── dnsforce/                               PF firewall + watchdog (blocks DoH/DoT/DoQ at kernel)
│       ├── README.md                           dnsforce-specific setup notes
│       ├── setup.sh                            One-shot installer (runs the three sub-scripts)
│       ├── install.sh, install-keeper.sh, lock.sh
│       ├── health.sh                           Read-only diagnostic (run with sudo)
│       ├── dnsforce-sync.sh, dnsforce-keeper.sh
│       ├── dnsforce.pf.conf                    PF main ruleset
│       ├── com.selfexclusion.dnsforce          PF anchor rules
│       ├── doh-endpoints.list                  ~80 public DoH IPs to block
│       ├── com.selfexclusion.dnsforce.plist    Main daemon LaunchDaemon
│       └── com.selfexclusion.dnsforce-keeper.plist  Watchdog LaunchDaemon
│
├── reference/                                  Copy-paste-into-Tech-Lockdown lists
│   ├── tld-macos-extra-blocklist.txt           94 domains (antidetect browsers, niche casinos)
│   ├── tld-ios-blocked-apps.txt                Bundle IDs to block on iOS (Kick, etc.)
│   └── tld-ios-web-content-filter.txt          High-priority iOS Web Content Filter deny list
│
└── screenshots/                                Referenced inline by guide.html
    └── (Tech Lockdown / Applivery UI screenshots)
```

## What this is not

- Not a single-product solution. It's seven layered mechanisms.
- Not free. Tech Lockdown is $9.99/month billed annually and effectively required. Applivery is optional but useful if you're a software engineer (€3/device/month on the Advanced plan, annual billing; the 14-day free trial is enough to set up and cancel).
- Not a substitute for therapy or peer support. See the last section of `guide.html`.
- Not affiliated with Cloudflare, Tech Lockdown, Applivery, or Apple.

## License

MIT. Full text in [`LICENSE`](LICENSE). Use it, fork it, redistribute it, fold it into your own guide.

## Maintenance & contributions

The repository is reviewed **every Sunday**. Pull requests, issues, and updated blocklists are merged/triaged on that weekly cadence.

**Top contribution priority: a Windows port.** Tech Lockdown, Cloudflare WARP, and Applivery already support Windows. What's needed is the Windows equivalent of the macOS-specific pieces (the `/etc/hosts` lock, the `dnsforce` PF firewall, and the DoH-disable configuration profile). The architecture maps cleanly — see the "Maintenance & contributions" section of `guide.html` for the specific Windows-side mechanisms (`icacls`, Windows Filtering Platform, browser policies via Registry).

Other contributions welcome: Linux variants, Android (via Applivery), more blocklists, translations.

## Anonymous release

The person who built and tested this setup is releasing it anonymously. No author, no donations, no contact address. The hope is that someone else who needs it finds it in time.

A.R.C.05.
