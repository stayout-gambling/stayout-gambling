#!/usr/bin/env python3
"""
Migrate domain blocklist from inline-domains Tech Lockdown rules to
Cloudflare Gateway Lists + a single umbrella DNS rule.

Three phases, each independently resumable:

  1. cleanup   Delete inline-domains rules created by the earlier
               Tech Lockdown bulk uploader. Detected by traffic-pattern
               signature (NOT by name).
  2. lists     Create ~63 Gateway Lists of up to 1,000 apex domains each
               from the supplied apex_only.txt.
  3. rule      Create one DNS Block rule whose expression references
               all created lists via `any(dns.domains[*] in $uuid)` OR'd
               together.

Parallelism: --workers N (default 20). Uses a thread pool with
exponential backoff on 429/5xx, honoring Retry-After headers.

Usage:
  python3 migrate_to_lists.py --phase cleanup --dry-run        # preview
  python3 migrate_to_lists.py --phase all --yes                # full run
  python3 migrate_to_lists.py --phase cleanup --workers 30     # tune

State lives in .cf_migration_state.json (resumable; safe to interrupt).
"""

import argparse
import json
import pathlib
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import requests
from requests.adapters import HTTPAdapter

# ─── config ──────────────────────────────────────────────────────────────
CF_API_BASE   = "https://api.cloudflare.com/client/v4"
CF_ACCOUNT_ID = "PASTE_YOUR_CLOUDFLARE_ACCOUNT_ID_HERE"
CF_API_TOKEN  = "PASTE_YOUR_CLOUDFLARE_API_TOKEN_HERE"

LIST_NAME_PREFIX = "Self-Exclusion Blocklist"
RULE_NAME        = "Self-Exclusion Blocklist (umbrella rule)"
LIST_CHUNK_SIZE  = 1000   # Standard plan cap per list

INLINE_PATTERN_PREFIX = 'any(dns.domains[*] in {"'
MIN_INLINE_ENTRIES    = 50

STATE_FILE = pathlib.Path(".cf_migration_state.json")
_state_lock = threading.Lock()

# ─── plumbing ────────────────────────────────────────────────────────────

def session(pool_size: int = 50) -> requests.Session:
    s = requests.Session()
    s.headers.update({
        "Authorization": f"Bearer {CF_API_TOKEN}",
        "Content-Type":  "application/json",
        "Accept":        "application/json",
    })
    adapter = HTTPAdapter(
        pool_connections=pool_size,
        pool_maxsize=pool_size,
        max_retries=0,
    )
    s.mount("https://", adapter)
    s.mount("http://", adapter)
    return s

def load_state() -> dict:
    if STATE_FILE.exists():
        return json.loads(STATE_FILE.read_text())
    return {"cleanup_deleted": [], "lists": {}, "final_rule": None}

def save_state(state: dict) -> None:
    """Caller must hold _state_lock."""
    STATE_FILE.write_text(json.dumps(state, indent=2))

def cf_ok(r: requests.Response) -> bool:
    if r.status_code == 204:
        return True
    if r.status_code not in (200, 201):
        return False
    try:
        return bool(r.json().get("success"))
    except Exception:
        return False

def _do_with_retry(fn, max_retries: int = 5) -> requests.Response:
    """Call `fn()` (returns a Response). Retry on 429/5xx with exponential
    backoff, honoring Retry-After if present."""
    last = None
    for attempt in range(max_retries + 1):
        try:
            r = fn()
        except requests.RequestException:
            if attempt == max_retries:
                raise
            time.sleep(min(2 ** attempt, 30))
            continue
        last = r
        if r.status_code not in (429, 500, 502, 503, 504):
            return r
        if attempt == max_retries:
            return r
        ra = r.headers.get("Retry-After")
        wait = None
        if ra:
            try:
                wait = float(ra)
            except (ValueError, TypeError):
                wait = None
        if wait is None:
            wait = 2 ** attempt
        time.sleep(min(wait, 30))
    return last

# ─── API helpers ─────────────────────────────────────────────────────────

def verify_token(s: requests.Session) -> bool:
    r = _do_with_retry(lambda: s.get(f"{CF_API_BASE}/user/tokens/verify", timeout=15))
    if cf_ok(r):
        print(f"  token OK (status: {r.json()['result']['status']})")
        return True
    print(f"  token verification failed: HTTP {r.status_code}: {r.text[:300]}")
    return False

def list_all_rules(s: requests.Session) -> list:
    print("          fetching all gateway rules (single call)...", flush=True)
    t0 = time.time()
    r = _do_with_retry(lambda: s.get(
        f"{CF_API_BASE}/accounts/{CF_ACCOUNT_ID}/gateway/rules",
        timeout=120,
    ))
    dt = time.time() - t0
    if not cf_ok(r):
        raise RuntimeError(
            f"list rules failed: HTTP {r.status_code} after {dt:.1f}s: {r.text[:400]}"
        )
    raw = r.json().get("result") or []
    seen, unique = set(), []
    for rule in raw:
        rid = rule.get("id")
        if rid and rid not in seen:
            seen.add(rid)
            unique.append(rule)
    print(f"          got {len(unique)} unique rule(s) in {dt:.1f}s "
          f"(raw response had {len(raw)})", flush=True)
    return unique

def delete_rule(s: requests.Session, rule_id: str) -> tuple[bool, requests.Response]:
    r = _do_with_retry(lambda: s.delete(
        f"{CF_API_BASE}/accounts/{CF_ACCOUNT_ID}/gateway/rules/{rule_id}",
        timeout=30,
    ))
    return cf_ok(r) or r.status_code == 404, r

def create_list(s: requests.Session, name: str, items: list[str]) -> requests.Response:
    body = {
        "name":        name,
        "description": "Auto-created by migrate_to_lists.py (self-exclusion blocklist)",
        "type":        "DOMAIN",
        "items":       [{"value": v} for v in items],
    }
    return _do_with_retry(lambda: s.post(
        f"{CF_API_BASE}/accounts/{CF_ACCOUNT_ID}/gateway/lists",
        json=body,
        timeout=120,
    ))

def list_all_lists(s: requests.Session) -> list:
    """Gateway lists endpoint also returns everything in one call."""
    r = _do_with_retry(lambda: s.get(
        f"{CF_API_BASE}/accounts/{CF_ACCOUNT_ID}/gateway/lists",
        timeout=60,
    ))
    if not cf_ok(r):
        raise RuntimeError(f"list-lists failed: HTTP {r.status_code}: {r.text[:300]}")
    return r.json().get("result") or []

def delete_list(s: requests.Session, list_id: str) -> tuple[bool, requests.Response]:
    r = _do_with_retry(lambda: s.delete(
        f"{CF_API_BASE}/accounts/{CF_ACCOUNT_ID}/gateway/lists/{list_id}",
        timeout=30,
    ))
    return cf_ok(r) or r.status_code == 404, r

def create_rule(s: requests.Session, name: str, traffic: str) -> requests.Response:
    body = {
        "name":        name,
        "description": "Umbrella DNS block rule referencing every blocklist list",
        "enabled":     True,
        "action":      "block",
        "filters":     ["dns"],
        "traffic":     traffic,
    }
    return _do_with_retry(lambda: s.post(
        f"{CF_API_BASE}/accounts/{CF_ACCOUNT_ID}/gateway/rules",
        json=body,
        timeout=30,
    ))

# ─── detection ───────────────────────────────────────────────────────────

def is_bulk_inline_rule(rule: dict) -> bool:
    if rule.get("action") != "block":
        return False
    if "dns" not in (rule.get("filters") or []):
        return False
    traffic = rule.get("traffic") or ""
    if INLINE_PATTERN_PREFIX not in traffic:
        return False
    return traffic.count('"') >= MIN_INLINE_ENTRIES * 2

# ─── phases ──────────────────────────────────────────────────────────────

def phase_wipe_lists(s, state, yes, workers):
    """Delete all gateway lists whose name starts with LIST_NAME_PREFIX,
    then clear state['lists']. Use this to start the lists phase over."""
    print(f"[wipe] fetching all gateway lists...")
    all_lists = list_all_lists(s)
    print(f"[wipe] account has {len(all_lists)} total gateway list(s).")

    targets = [L for L in all_lists if (L.get("name") or "").startswith(LIST_NAME_PREFIX)]
    print(f"[wipe] {len(targets)} match prefix {LIST_NAME_PREFIX!r}.")

    if not targets:
        with _state_lock:
            state["lists"] = {}
            save_state(state)
        print("[wipe] nothing on the server. Cleared state.lists.")
        return True

    print("[wipe] sample of matches:")
    for L in targets[:3]:
        print(f"       id={L['id']}  name={L.get('name')!r}  count={L.get('count')}")
    if len(targets) > 3:
        print(f"       ... and {len(targets) - 3} more")

    if not yes:
        ans = input(f"[wipe] delete these {len(targets)} lists? [y/N]: ").strip().lower()
        if ans != "y":
            print("[wipe] aborted by user.")
            return False

    print(f"[wipe] deleting {len(targets)} lists with {workers} parallel workers...")
    counter = {"done": 0, "fail": 0}
    failures = []
    t0 = time.time()

    def _worker(L):
        lid = L["id"]
        ok, r = delete_list(s, lid)
        with _state_lock:
            if ok:
                counter["done"] += 1
                if counter["done"] % 10 == 0 or \
                   counter["done"] + counter["fail"] == len(targets):
                    elapsed = time.time() - t0
                    rate = counter["done"] / elapsed if elapsed > 0 else 0
                    print(f"[wipe] {counter['done']:3d}/{len(targets)} done "
                          f"({rate:.1f}/s, {counter['fail']} failed)", flush=True)
            else:
                counter["fail"] += 1
                failures.append((lid, r.status_code, r.text[:200]))

    with ThreadPoolExecutor(max_workers=min(workers, 10)) as ex:
        for _ in ex.map(_worker, targets):
            pass

    with _state_lock:
        state["lists"] = {}
        save_state(state)

    elapsed = time.time() - t0
    print(f"[wipe] phase done in {elapsed:.1f}s. "
          f"{counter['done']} deleted, {counter['fail']} failed. "
          f"state.lists cleared.")
    if failures:
        print("[wipe] first failures:")
        for lid, code, msg in failures[:5]:
            print(f"       {lid}: HTTP {code}: {msg}")
        return False
    return True


def phase_cleanup(s, state, dry_run, yes, workers):
    print("[cleanup] fetching all gateway rules...")
    all_rules = list_all_rules(s)
    print(f"[cleanup] account has {len(all_rules)} total gateway rule(s).")

    targets = [r for r in all_rules if is_bulk_inline_rule(r)]
    print(f"[cleanup] {len(targets)} match the bulk-inline-rule signature.")

    if not targets:
        print("[cleanup] nothing to delete.")
        return True

    print("[cleanup] sample of matches:")
    for r in targets[:3]:
        name    = r.get("name") or "(no name)"
        traffic = (r.get("traffic") or "")[:80]
        print(f"          id={r['id']}  name={name!r}  traffic={traffic!r}...")
    if len(targets) > 3:
        print(f"          ... and {len(targets) - 3} more")

    if dry_run:
        print("[cleanup] --dry-run set; not deleting.")
        return True

    if not yes:
        ans = input(f"[cleanup] delete these {len(targets)} rules? [y/N]: ").strip().lower()
        if ans != "y":
            print("[cleanup] aborted by user.")
            return False

    deleted = set(state.get("cleanup_deleted", []))
    remaining = [r for r in targets if r["id"] not in deleted]
    if not remaining:
        print("[cleanup] all targets already deleted in prior runs.")
        return True

    print(f"[cleanup] deleting {len(remaining)} rules with {workers} parallel workers...")
    counter = {"done": 0, "fail": 0, "last_logged": 0}
    failures = []
    t0 = time.time()

    def _worker(rule):
        rid = rule["id"]
        ok, r = delete_rule(s, rid)
        with _state_lock:
            if ok:
                counter["done"] += 1
                deleted.add(rid)
                state["cleanup_deleted"] = sorted(deleted)
                done_total = counter["done"] + counter["fail"]
                if counter["done"] - counter["last_logged"] >= 25 or \
                   done_total == len(remaining):
                    save_state(state)
                    counter["last_logged"] = counter["done"]
                    elapsed = time.time() - t0
                    rate = counter["done"] / elapsed if elapsed > 0 else 0
                    print(f"[cleanup] {counter['done']:4d}/{len(remaining)} done "
                          f"({rate:.1f}/s, {counter['fail']} failed)",
                          flush=True)
            else:
                counter["fail"] += 1
                failures.append((rid, r.status_code, r.text[:200]))

    with ThreadPoolExecutor(max_workers=workers) as ex:
        for _ in ex.map(_worker, remaining):
            pass

    with _state_lock:
        save_state(state)

    elapsed = time.time() - t0
    print(f"[cleanup] phase done in {elapsed:.1f}s. "
          f"{counter['done']} deleted, {counter['fail']} failed.")
    if failures:
        print("[cleanup] first failures:")
        for rid, code, msg in failures[:5]:
            print(f"          {rid}: HTTP {code}: {msg}")
        return False
    return True


def phase_lists(s, state, apex_path, dry_run, workers):
    if not apex_path.exists():
        print(f"[lists] error: {apex_path} not found")
        return False

    domains = [
        line.strip().lower()
        for line in apex_path.read_text().splitlines()
        if line.strip() and not line.startswith("#")
    ]
    seen, deduped = set(), []
    for d in domains:
        if d not in seen:
            seen.add(d)
            deduped.append(d)
    domains = deduped
    print(f"[lists] loaded {len(domains)} apex domains from {apex_path}")

    cap = 100 * LIST_CHUNK_SIZE
    if len(domains) > cap:
        print(f"[lists] WARNING: {len(domains)} > Standard plan capacity ({cap}). Truncating.")
        domains = domains[:cap]

    chunks = [domains[i:i + LIST_CHUNK_SIZE] for i in range(0, len(domains), LIST_CHUNK_SIZE)]
    print(f"[lists] will create {len(chunks)} list(s) of up to {LIST_CHUNK_SIZE} entries each.")

    if dry_run:
        for i, chunk in enumerate(chunks[:3], 1):
            print(f"[lists]   would create '{LIST_NAME_PREFIX} {i:04d}' with "
                  f"{len(chunk)} entries (first: {chunk[0]}, last: {chunk[-1]})")
        if len(chunks) > 3:
            print(f"[lists]   ... and {len(chunks) - 3} more")
        return True

    existing = state.get("lists", {})
    pending = [(idx, chunk) for idx, chunk in enumerate(chunks, 1)
               if f"{idx:04d}" not in existing]
    if not pending:
        print(f"[lists] all {len(chunks)} list(s) already exist in state.")
        return True

    worker_count = min(workers, 10)
    if worker_count != workers:
        print(f"[lists] capping workers at {worker_count} (Lists API limit is 600/min)")

    print(f"[lists] creating {len(pending)} list(s) with {worker_count} parallel workers...")
    counter = {"done": 0, "fail": 0}
    failures = []
    t0 = time.time()

    def _worker(item):
        idx, chunk = item
        key  = f"{idx:04d}"
        name = f"{LIST_NAME_PREFIX} {idx:04d}"
        r = create_list(s, name, chunk)
        with _state_lock:
            if cf_ok(r):
                uuid = r.json()["result"]["id"]
                existing[key] = {"uuid": uuid, "name": name, "count": len(chunk)}
                state["lists"] = existing
                save_state(state)
                counter["done"] += 1
                elapsed = time.time() - t0
                rate = counter["done"] / elapsed if elapsed > 0 else 0
                print(f"[lists] {counter['done']:3d}/{len(pending)} "
                      f"✓ {name} → {uuid[:8]}... ({rate:.1f}/s)",
                      flush=True)
            else:
                counter["fail"] += 1
                failures.append((name, r.status_code, r.text[:300]))
                print(f"[lists] ✗ {name}: HTTP {r.status_code}: {r.text[:200]}",
                      flush=True)

    with ThreadPoolExecutor(max_workers=worker_count) as ex:
        for _ in ex.map(_worker, pending):
            pass

    elapsed = time.time() - t0
    print(f"[lists] phase done in {elapsed:.1f}s. "
          f"{counter['done']} created, {counter['fail']} failed.")
    if failures:
        print("[lists] first failures:")
        for name, code, msg in failures[:5]:
            print(f"        {name}: HTTP {code}: {msg}")
        return False
    return True


def phase_rule(s, state, dry_run):
    lists = state.get("lists", {})
    if not lists:
        print("[rule] no lists in state. Run --phase lists first.")
        return False

    uuids = [v["uuid"] for _, v in sorted(lists.items())]
    parts = [f"any(dns.domains[*] in ${u})" for u in uuids]
    traffic = " or ".join(parts)
    print(f"[rule] building expression with {len(uuids)} list reference(s).")
    print(f"[rule] expression length: {len(traffic)} chars (cap: 140,000)")

    if state.get("final_rule"):
        print(f"[rule] umbrella rule already exists in state: {state['final_rule']}")
        return True

    if dry_run:
        print(f"[rule] would create rule '{RULE_NAME}' with action=block, filters=[dns]")
        return True

    r = create_rule(s, RULE_NAME, traffic)
    if cf_ok(r):
        rid = r.json()["result"]["id"]
        print(f"[rule] ✓ umbrella rule created: {rid}")
        with _state_lock:
            state["final_rule"] = rid
            save_state(state)
        return True
    print(f"[rule] ✗ HTTP {r.status_code}: {r.text[:500]}")
    return False

# ─── main ────────────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--phase", required=True,
                    choices=["cleanup", "wipe-lists", "lists", "rule", "all"])
    ap.add_argument("--apex-file", default="apex_only.txt")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--yes", action="store_true",
                    help="skip the confirmation prompt before bulk deletion")
    ap.add_argument("--workers", type=int, default=20,
                    help="parallel workers (default: 20, lists phase capped at 10)")
    args = ap.parse_args()

    s = session(pool_size=max(50, args.workers + 5))

    print("Verifying API token...")
    if not verify_token(s):
        return 1
    print()

    state = load_state()

    if args.phase == "wipe-lists":
        if not phase_wipe_lists(s, state, yes=args.yes, workers=args.workers):
            return 2
        print()

    if args.phase in ("cleanup", "all"):
        if not phase_cleanup(s, state, dry_run=args.dry_run, yes=args.yes,
                              workers=args.workers):
            return 2
        print()

    if args.phase in ("lists", "all"):
        if not phase_lists(s, state, pathlib.Path(args.apex_file),
                            dry_run=args.dry_run, workers=args.workers):
            return 2
        print()

    if args.phase in ("rule", "all"):
        if not phase_rule(s, state, dry_run=args.dry_run):
            return 2
        print()

    print("All requested phase(s) completed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())