# `mihomo daemon` / Lifecycle / Diagnostics — Command Group Specification

Covers the remaining groups from §6.5 and §6.6 of the design doc: process supervision (`daemon`), manual lifecycle control (`start`/`stop`/`restart`), and diagnostics (`log`, `audit`, `doctor`, `uninstall`). Follows the conventions established in the `sub`, `net`, `kernel`, and `mode` specs.

## Global conventions for this section

- All commands accept `--json` except `log --follow` (streaming output isn't meaningfully JSON-per-line unless `--json` explicitly requests NDJSON, which it does — see below).
- `daemon install/remove` and `uninstall` acquire the advisory lock (§3); read-only commands (`daemon status`, `log`, `audit`, `doctor`, `start`/`stop`/`restart` also mutate but are exempted from the *config-mutation* lock since they don't touch config files — they still respect the kernel process lock from §4.1.2).
- Exit codes reuse the base table, plus the group-specific additions already defined (`6` privilege/entitlement, `8` source verification / binary presence failure) where relevant.

---

## `mihomo daemon install`

```
mihomo daemon install [--yes]
```

Installs the per-user `launchd` agent described in §2.3 that provides auto-restart and persistence beyond terminal closure. This is typically run once during first-time setup (and can be triggered automatically the first time `net tun on` or `kernel use` is run, per §2.3 and the `net tun` spec — in which case this command is idempotent and simply reports "already installed").

```
Installing launchd agent at ~/Library/LaunchAgents/com.mihomo-cli.agent.plist
✅ Daemon installed. mihomo will now auto-restart on crash and persist after this terminal closes.
```

**Exit codes:** `0` success or already installed · `6` failed to write the plist (permission issue) · `4` concurrent daemon operation in progress.

---

## `mihomo daemon remove`

```
mihomo daemon remove [--yes]
```

Unloads and deletes the `launchd` agent. Does **not** stop a currently running kernel — it only removes supervision, so a manually-started kernel keeps running until stopped explicitly. This distinction is called out because it's easy to assume "remove daemon" means "stop everything":

```
✅ Daemon removed. The kernel is still running (pid 4102) but will no longer auto-restart if it crashes, and won't persist after you close this terminal.
Run 'mihomo stop' if you also want to stop it now.
```

**Exit codes:** `0` success or already absent · `4` concurrent daemon operation in progress.

---

## `mihomo daemon status`

```
mihomo daemon status [--json]
```

```
Installed:      yes
Agent state:    running
Restart count:  2 (since install)
Last restart:   2026-08-09 03:14 — reason: kernel crashed (exit code 139)
```

If never crashed, `Restart count: 0` and `Last restart: never`. If not installed:
```
Installed: no
Note: run 'mihomo daemon install' to enable auto-restart and persistence.
```

**Exit codes:** `0` always.

---

## `mihomo start` / `stop` / `restart`

```
mihomo start [--version <version>]
mihomo stop
mihomo restart
```

Manual lifecycle control, independent of daemon supervision — these work whether or not the `launchd` agent is installed.

- `start`: launches the currently active kernel (or `--version` if given, without changing which kernel is marked active — a one-off run). Runs the same on-disk presence check and liveness check as `kernel use` (§4.1.3). Refuses to start if a kernel is already running (use `restart` instead):
  ```
  error: kernel already running (pid 4102) — use 'mihomo restart' to restart it, or 'mihomo stop' first
  ```
- `stop`: graceful shutdown (SIGTERM, wait, then SIGKILL after a timeout). Marks the stop as user-initiated so the daemon (if installed) does **not** treat it as a crash requiring auto-restart — this distinction is what makes §4.1.2's "auto-restart on unexpected crashes not triggered by user-initiated stop" work correctly.
- `restart`: `stop` followed by `start`, atomic from the user's perspective (single lock hold, single status line), with the same rollback-on-failure behavior as other atomic operations — if the restart's liveness check fails, it does not leave the kernel in a stopped state; it attempts to bring the previous configuration back up.

**Exit codes:** `0` success · `2` already running (`start`) or not running (`stop`) · `8` binary missing or zero-length on disk · other kernel-failure cases mirror `kernel use`'s staged-failure reporting.

---

## `mihomo log`

```
mihomo log [--level info|warning|error] [--follow] [--json]
```

Tails the leveled logs from §4.1.5. `--level` filters to that level and above (`warning` shows warning+error, not info). `--follow` behaves like `tail -f`. `--json` with `--follow` emits newline-delimited JSON (NDJSON), one log entry per line, suitable for piping to `jq` or a log aggregator.

**Output (human, non-follow):**
```
2026-08-12 09:14:02 [info]    kernel: switched to v1.19.10
2026-08-12 09:14:03 [warning] net: system proxy already set on 'Wi-Fi', overwritten with confirmation
2026-08-09 03:14:11 [error]   kernel: process exited unexpectedly (exit code 139)
```

Respects the rotation policy from §4.1.6 — `log` without `--follow` reads across rotated files transparently up to the retained window (5 files by default) if the requested range spans a rotation boundary.

**Exit codes:** `0` always (empty log is not an error).

---

## `mihomo audit`

```
mihomo audit [--since <date>] [--action <type>] [--json]
```

Queries the audit trail from §4.1.5 (timestamp, action type, target object, execution result). `--since` accepts `YYYY-MM-DD` or relative forms (`7d`, `24h`). `--action` filters to a specific action type (e.g. `kernel.use`, `sub.switch`, `net.system-proxy`).

**Output (human):**
```
2026-08-12 09:14:03  kernel.use     target=v1.19.10        result=success
2026-08-11 22:03:41  sub.switch     target=work-vpn        result=rolled-back (liveness check failed)
2026-08-10 06:00:00  sub.refresh    target=work-vpn         result=success
```

Audit entries are read-only and immutable per §4.1.5 — this command never modifies the trail, only queries it.

**Exit codes:** `0` always.

---

## `mihomo doctor`

```
mihomo doctor [--json]
```

Runs every pre-flight check from §4.1.3 without applying any changes — a dry-run diagnostic. Useful before attempting a switch that's expected to be risky, or as a first troubleshooting step.

**Checks performed:**
- Active kernel binary presence/intactness on disk (existence + non-zero size only — no SHA256 recheck, see §4.1.3)
- Active subscription format/rule/param validity
- Port availability for the configured mixed-port
- System proxy state consistency (does the OS-level setting match what this tool believes is active)
- Tun entitlement status (granted / not granted)
- `launchd` agent presence and health
- Disk space and log rotation headroom

**Output (human):**
```
Kernel binary present ..... ✅ passed (v1.19.10)
Subscription validity ..... ✅ passed (work-vpn)
Port 7890 availability .... ✅ free
System proxy consistency .. ⚠  mismatch — OS reports proxy on 'Ethernet', tool expects 'Wi-Fi'
Tun entitlement ............ ✅ granted
Daemon health .............. ✅ running, 0 unexpected restarts
Disk / log headroom ........ ✅ ok

1 warning found. Run 'mihomo net system-proxy off' then re-enable to resync, or investigate manually.
```

Never exits non-zero for warnings alone — only for a check that couldn't be completed at all (e.g. kernel binary missing entirely).

**Exit codes:** `0` completed (regardless of warnings found) · `8` a check could not run because the kernel binary is missing or zero-length on disk.

---

## `mihomo uninstall`

```
mihomo uninstall [--purge-data] [--yes]
```

Full teardown per §2.5, run in a fixed, safe order so a failure partway through doesn't leave a worse state than before:

1. Stop the kernel if running (as a user-initiated stop, so no auto-restart races with the teardown)
2. Remove the `launchd` agent (§2.3)
3. Revert System Proxy settings if currently applied by this tool
4. Tear down the Tun virtual interface if active
5. *(only with `--purge-data`)* Remove downloaded kernel binaries, subscriptions, and logs

Each step reports success/failure independently rather than aborting the whole sequence on the first failure, since partial cleanup is still strictly better than none:

```
Uninstalling mihomo-cli...
  ✅ Kernel stopped
  ✅ launchd agent removed
  ✅ System proxy reverted (Wi-Fi)
  ⚠  Tun interface teardown failed — utun3 may require manual removal (see 'ifconfig utun3 destroy')
Uninstall completed with 1 warning. Config and logs were preserved (use --purge-data to remove them too).
```

Without `--purge-data`, config/subscriptions/logs are left on disk intentionally, so a reinstall can pick up where the user left off.

**Exit codes:** `0` completed (including with individual step warnings) · `2` declined confirmation prompt.
