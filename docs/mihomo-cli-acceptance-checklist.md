# mihomo-cli acceptance checklist

Rule for every step below: the CLI printing "✅ Success" is **not** the pass
criterion. Every step has a separate, independent check — `ps`, `lsof`,
`curl`, or a fresh `doctor` run — because this project's whole history so
far has been the CLI reporting success while doing nothing. Don't skip the
independent check even when the CLI output looks fine.

Work through phases in order — later phases assume earlier ones passed.

---

## Phase 0 — Build & install (prerequisite)

```bash
bash run-task-flow.sh build
bash run-task-flow.sh test
bash run-task-flow.sh install
```

**Pass:** all three exit 0, no `error:` lines. `which -a mihomo-cli` shows
exactly `/usr/local/bin/mihomo-cli`. `mihomo-cli --help` prints the command
tree.

---

## Phase 1 — Kernel management

```bash
mihomo-cli kernel list
```
**Pass:** shows at least one installed version. If none, `mihomo-cli kernel
fetch <version>` first.

```bash
mihomo-cli kernel use <version>
ps aux | grep mihomo
```
**Pass:** a `mihomo` process appears, owned by **your username**, not root.
(If it says "already the active kernel, nothing to do" and `ps` shows
nothing running, that's the known gap noted earlier — use `mihomo-cli
start` instead for this check.)

```bash
mihomo-cli kernel status
```
**Pass:** reports the same PID you saw in `ps aux`.

---

## Phase 2 — Subscription

```bash
mihomo-cli sub list
```
If empty:
```bash
mihomo-cli sub add <name> --file /path/to/your/config.yaml
mihomo-cli sub use <name>
```
**Pass:** `sub list` shows it marked active, no `flagged invalid` warning.

---

## Phase 3 — start / stop / restart (this round's config-write fix)

Stop whatever's running first so this is a clean test of `start`, not
`kernel use`:
```bash
mihomo-cli stop
ps aux | grep mihomo   # should show nothing
```

```bash
mihomo-cli start
ps aux | grep mihomo
```
**Pass:** process is running, owned by your user. This is the exact path
that was broken (kernel launched against a config file that was never
written) — if this fails with "kernel started but did not respond," that
fix didn't take; paste the full error.

```bash
mihomo-cli restart
ps aux | grep mihomo
```
**Pass:** new PID, still running, still your user.

**Strongest possible check — confirm it's actually proxying traffic:**
```bash
curl -x http://127.0.0.1:7890 -s -o /dev/null -w "%{http_code}\n" https://www.google.com
```
**Pass:** `200`. This is the one check in this whole list that proves
traffic is actually flowing through the kernel, not just that a process
exists and a port is open.

---

## Phase 4 — mode switching

```bash
mihomo-cli mode rule
mihomo-cli mode status
mihomo-cli mode global
mihomo-cli mode status
```
**Pass:** `mode status` reflects the switch each time (queries the running
kernel's actual `/configs`, not just local metadata).

---

## Phase 5 — System Proxy

```bash
mihomo-cli net system-proxy on
networksetup -getwebproxy "Wi-Fi"    # or your active service, e.g. "USB Ethernet"
```
**Pass:** shows `Enabled: Yes` and `Server: 127.0.0.1` `Port: 7890` (or
whatever port your kernel is on).

```bash
mihomo-cli net system-proxy off
networksetup -getwebproxy "Wi-Fi"
```
**Pass:** `Enabled: No`.

---

## Phase 6 — Proxy-mode with custom port (this session's PATCH fix)

```bash
mihomo-cli net proxy-mode on --port 8899
lsof -i :8899
```
**Pass:** `lsof` shows `mihomo` actually listening on 8899. This is the
check that matters — the CLI could print "port 8899" while the kernel is
still on 7890; `lsof` is the independent source of truth.

```bash
curl -x http://127.0.0.1:8899 -s -o /dev/null -w "%{http_code}\n" https://www.google.com
```
**Pass:** `200` — confirms the new port is actually serving traffic, not
just open.

```bash
mihomo-cli net off
```

---

## Phase 7 — Tun mode (this conversation's elevation fix)

**Prerequisite:** quit any other VPN/proxy client with an active TUN
interface first (Surge, ClashX, another mihomo instance, etc.) —
`ifconfig -a | grep -A2 utun` should show no `utun*` that's both `UP` and
has a real `inet`/non-link-local `inet6` address. If one does, that's a
real conflict to resolve, not a bug in this tool (confirmed in the last
round — see `utun6` / `198.18.0.1` in your earlier output).

```bash
ps aux | grep mihomo   # note current owner (should be your user)
mihomo-cli net tun on
```
**Pass:** prompts for your Mac password. Then:
```bash
ps aux | grep mihomo
```
**Pass:** owner is now **root**. This is the single most important check
in this entire list — it's the one the "fix" was specifically about.

```bash
mihomo-cli doctor
```
**Pass:** `Tun entitlement` line shows `granted`, no new password prompt.

```bash
mihomo-cli net tun off
ps aux | grep mihomo
```
**Pass:** owner is back to your username.

---

## Phase 8 — doctor, standalone

```bash
mihomo-cli doctor
```
**Pass:** every check reflects real state — compare each line against what
you independently know to be true (kernel running or not, subscription
active or not, Tun usable or not). No hardcoded `passed` regardless of
reality — that was the original bug in this exact command.

---

## What "ready to use daily" means

All of Phases 0–6 passing, on their own, is enough for this to be a usable
kernel/subscription/proxy manager — that covers System Proxy and
port-based proxy mode end to end, including real traffic through `curl`.

Phase 7 (Tun mode) passing is a separate, additional bar — don't block
daily use on it if you don't specifically need system-wide traffic
interception. If Phase 7 fails, you can still use Phases 0–6 safely; just
don't run `net tun on` until it's resolved.

If any phase fails, paste: the exact command, the full output, and the
result of that phase's independent check (`ps`/`lsof`/`curl`) — that's
what let us find the real bugs the last two rounds instead of guessing.
