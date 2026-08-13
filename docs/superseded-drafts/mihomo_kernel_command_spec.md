# `mihomo kernel` — Command Group Specification

Covers argument grammar, flags, output format, exit codes, and error message conventions for the kernel version management command group (§1.1, §6.1 of the design doc). Follows the same conventions established in the `sub` and `net` group specs.

## Global conventions for this group

- All commands accept `--json`.
- All mutating commands (`fetch`, `use`, `rm`) acquire the advisory lock (§3).
- Error format and exit code table match the base table from the `sub` spec, with one addition specific to this group:

| Code | Meaning |
|---|---|
| `8` | Source verification failed (download did not resolve to an official release asset) |

---

## `mihomo kernel list`

```
mihomo kernel list [--json] [--sort active|last-used|version|added]
```

Default sort matches §1.1.1: Active > Last Used > Version > Added Time. `--sort` overrides to a single key, descending.

**Output (human):**
```
  STATUS  VERSION          LAST USED         ADDED
  ✅      v1.19.10          2026-08-12 09:14  2026-07-01 12:00
          v1.19.8           2026-07-28 21:03  2026-07-15 08:44
          v1.20.0-alpha.3                     2026-08-05 10:20
```

**Exit codes:** `0` always (empty list prints `No kernels installed. Run 'mihomo kernel check' or 'mihomo kernel fetch' to get one.`).

---

## `mihomo kernel check`

```
mihomo kernel check [--yes]
```

Fetches the latest stable release metadata from upstream (§1.1.3), compares against the currently active kernel's version.

**If a newer stable release exists:**
```
A newer stable release is available: v1.19.11 (published 2026-08-10)
Currently active: v1.19.10
Download and switch to it? [y/N]
```
`--yes` skips the prompt. Accepting runs `kernel fetch v1.19.11` followed by `kernel use v1.19.11` as a combined atomic operation — if either step fails, no partial state (downloaded-but-not-switched, or vice versa) is left; the fetch is rolled back too if the subsequent switch fails validation.

**If already current:**
```
Local version v1.19.10 is already the latest stable release. Nothing to do.
```

**Exit codes:** `0` success or already current · `1` fetch-and-switch declined by user (not an error, informational exit `0` actually — see note) · `5` network error reaching upstream · `8` source verification failed (download did not resolve to an official release asset).

> Note: declining the prompt is not a failure state — exits `0` with `Update available but not applied. Run 'mihomo kernel fetch v1.19.11' to get it without switching.`

---

## `mihomo kernel fetch`

```
mihomo kernel fetch [--all] [<version>]
```

- No arguments: fetches the latest stable only (same as the download portion of `kernel check`).
- `--all`: fetches the latest 10 releases across stable/alpha/beta/pre-release per §1.1.3. Versions already present locally are skipped and reported as such, not re-downloaded:
  ```
  Fetching latest 10 releases...
    v1.20.0-alpha.3   downloaded
    v1.19.11          downloaded
    v1.19.10          already present, skipped
    v1.19.9           downloaded
    ...
  Latest stable: v1.19.11 (highlighted above)
  ```
- `<version>` (explicit tag, e.g. `v1.18.2-alpha`): fetches that specific release directly via the upstream release-by-tag API, bypassing the top-10 window (§1.1.3 pinning capability). Errors clearly if the tag doesn't exist upstream:
  ```
  error: no release found for tag 'v1.18.2-alpha' (root cause: not present in upstream release list) (fix: check available tags at <releases-url>, or run 'mihomo kernel fetch --all' to see recent ones)
  ```
- `--all` and `<version>` are mutually exclusive; combining them exits `1` with a usage error.

**Provenance handling (§4.1.3):** Every download is made directly against the official upstream releases API for the exact requested tag; no separate local checksum verification is performed. If the response doesn't resolve to a valid official release asset for that tag (bad redirect, 404, malformed artifact), the download is discarded entirely and never registered:
```
error: source verification failed for v1.19.11 — response did not resolve to an official release asset (root cause: unexpected redirect or malformed download, possibly a corporate proxy or MITM interfering) (fix: retry; if this persists, check whether your network is intercepting HTTPS traffic to github.com)
```

**Download resilience (§4.1.4):** Interrupted downloads resume automatically on retry rather than restarting from zero; up to 3 automatic retries on transient network failure before surfacing an error.

**Exit codes:** `0` success (including all-skipped case) · `1` usage error (conflicting flags) or unknown tag · `5` network error · `8` source verification failed (download did not resolve to an official release asset).

---

## `mihomo kernel use <version>`

```
mihomo kernel use <version> [--force]
```

Runs the atomic switch workflow (§4.1.1): backup current binary reference → confirm the target binary is still present and intact on disk (existence + non-zero size check; no SHA256 recheck is performed, per §4.1.3's official-repository trust model) → stop current kernel → start target kernel → liveness check (confirm the control API responds and the configured mixed-port is listening) → persist as active.

On failure at any stage, automatic rollback to the previously active kernel, with the same staged failure reporting style as `sub use`:
```
error: kernel switch aborted at 'liveness check' — new kernel process exited immediately (exit code 1)
Rolled back to 'v1.19.10'. No change was applied.
Run 'mihomo log --level error' for the kernel's stderr output.
```

Hard restriction (§1.1.2): switching to the currently active version is a no-op, not an error:
```
'v1.19.10' is already the active kernel. Nothing to do.
```

`--force` does **not** bypass the on-disk presence/intactness check — that check is non-negotiable per §4.1.3. It only bypasses the confirmation prompt shown when an active subscription is currently using features not supported by the target kernel version (e.g. downgrading past a version where a protocol was added), which is a warning, not a validation failure:
```
warning: active subscription 'work-vpn' uses Hysteria2 outbounds. Target kernel v1.15.2 may not support this protocol.
Switch anyway? [y/N]
```

**Exit codes:** `0` success or already-active no-op · `2` target is the currently running kernel mid-switch-away (shouldn't normally occur given the no-op case, reserved for race conditions) · `4` concurrent kernel operation in progress · `8` binary missing or zero-length on disk (switch refused, cannot be forced).

---

## `mihomo kernel rm <version>`

```
mihomo kernel rm <version> [--yes]
```

Blocked if `<version>` is the currently running kernel (§1.1.2), regardless of `--yes`:
```
error: cannot remove 'v1.19.10' — it is the currently running kernel (root cause: hard restriction, §1.1.2) (fix: switch to a different kernel first with 'mihomo kernel use <other-version>')
```
Otherwise prompts for confirmation unless `--yes`. Deletion removes the binary and its local metadata (added/last-used timestamps) but never touches subscriptions or logs.

**Exit codes:** `0` removed · `2` target is the active kernel · `3` not found.

---

## `mihomo kernel status`

```
mihomo kernel status [--json]
```

Shows the currently running kernel's version, uptime, control-port health, and last on-disk presence check result.

**Output (human):**
```
Version:       v1.19.10
Status:        running (pid 4102)
Uptime:        2h 14m
Control API:   responsive (127.0.0.1:9090)
Last presence check: 2026-08-12 09:14, passed
Supervised:    yes (launchd agent active)
```

If no kernel is running:
```
Status: not running
Note: run 'mihomo start' or 'mihomo kernel use <version>' to launch one.
```

**Exit codes:** `0` always.
