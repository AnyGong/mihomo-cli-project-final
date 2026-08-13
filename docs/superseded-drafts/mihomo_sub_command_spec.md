# `mihomo sub` — Command Group Specification

Covers argument grammar, flags, output format, exit codes, and error message conventions for the subscription command group (§1.2, §6.2 of the design doc). This is the template other groups (`kernel`, `net`, `mode`) should follow.

## Global conventions for this group

- All commands accept `--json` to emit machine-readable output instead of the human table/summary. Useful for scripting and for the tool's own tests.
- All mutating commands (`add`, `use`, `edit`, `rm`, `refresh`) acquire the advisory lock (§3) before running and release it on exit, including on error.
- Error messages follow the format: `error: <what failed> — <root cause> (<suggested fix>)`. No stack traces in default output; `--verbose` shows the underlying error chain.
- Exit codes are consistent across the whole CLI, not just this group:

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Validation failure (bad YAML, rule syntax, param error) |
| `2` | Permission denied (target is locked/active, or filesystem permission) |
| `3` | Not found (no subscription with that name) |
| `4` | Conflict (name collision, concurrent operation in progress) |
| `5` | Network error (remote fetch failed, timeout, DNS) |
| `130` | Interrupted by user (Ctrl-C) |

---

## `mihomo sub list`

```
mihomo sub list [--json] [--sort active|last-used|updated|added]
```

Default sort matches §1.2.1: Active > Last Used > Updated Time > Added Time. `--sort` overrides to a single key, descending.

**Output (human):**
```
  STATUS  NAME          PATH                 LAST USED         UPDATED           LOCAL  REMOTE  REFRESH
  ✅      home-fiber     home-fiber.yaml      2026-08-12 09:14  2026-08-12 09:14  ✅            Watch-on-use
          work-vpn       work-vpn.yaml        2026-08-10 18:02  2026-08-10 06:00         ✅     60 min
```

**Exit codes:** `0` always (empty list is not an error; prints `No subscriptions configured. Run 'mihomo sub add' to import one.`).

---

## `mihomo sub add`

```
mihomo sub add local <path> [--name <name>]
mihomo sub add remote <url> [--interval <minutes>] [--name <name>]
```

- `--interval` default `60`, range `1–1440`. Values outside range → exit `1` with `error: invalid --interval — must be between 1 and 1440 minutes`.
- Name collision handling per §1.2.3: if `--name` (or the derived default) already exists at the same source path, prompt `Overwrite existing subscription 'home-fiber'? [y/N]`. Non-interactive contexts (`--yes` / `--no` flags, or piped stdin) skip the prompt: `--yes` overwrites, default declines and appends a numeric suffix (`home-fiber-2`).
- Runs full format/rule/param validation (§1.2.2) before the entry is persisted. On failure, nothing is written — exit `1`, message lists each validation error on its own line, prefixed with the line number where applicable:
  ```
  error: subscription rejected — 2 validation errors
    line 14: unknown proxy type 'vmess2'
    line 41: rule-provider 'ads' has no matching path or url
  ```

**Exit codes:** `0` success · `1` validation failure · `4` name collision declined without a resolvable suffix (extremely rare) · `5` remote fetch failed (for `add remote`).

---

## `mihomo sub use <name>`

```
mihomo sub use <name> [--force]
```

Runs pre-switch validation (§1.2.2), then the atomic switch workflow (§4.1.1): backup current → validate target → temp-write → liveness check against the running kernel → persist. On any failure at any stage, automatic rollback to the previously active subscription, and the command reports which stage failed:

```
error: subscription switch aborted at 'liveness check' — kernel rejected config (invalid DNS nameserver)
Rolled back to 'home-fiber'. No change was applied.
```

`--force` is **not** permitted to bypass validation — it only suppresses the interactive confirmation step when switching away from a subscription with unsaved manual edits detected via mtime. It cannot be used to activate a subscription that fails validation; that always exits `1` regardless of flags.

Mode precedence note (§2.4) is printed on success if the subscription's embedded `mode` differs from the currently effective rule mode:
```
✅ Switched to 'work-vpn'.
Note: subscription default mode is 'global', but 'rule' is currently in effect (CLI override). Run 'mihomo mode global' to match the subscription default, or leave as-is.
```

**Exit codes:** `0` success · `1` validation failure (switch aborted, rolled back) · `2` target is already active, or another subscription is active and locked mid-switch · `4` concurrent switch already in progress.

---

## `mihomo sub edit <name>`

```
mihomo sub edit <name> [--editor <cmd>]
```

Opens the file in `$EDITOR` (or `--editor`). Blocked entirely — not even opened — if `<name>` is the active subscription:
```
error: cannot edit 'home-fiber' — it is the active subscription (root cause: hot edits risk desyncing the running kernel) (fix: switch to another subscription first, or use 'mihomo sub use --force' after editing a copy)
```
After the editor exits, the file is re-validated automatically; validation failures are reported but the edit is **not** reverted (it's the user's file) — the subscription is instead flagged `⚠ invalid` in `sub list` until fixed or re-validated.

**Exit codes:** `0` edited (valid or invalid — see above) · `2` target is active · `3` not found.

---

## `mihomo sub rm <name>`

```
mihomo sub rm <name> [--yes]
```

Blocked if active (exit `2`). Otherwise prompts for confirmation unless `--yes`. Does not touch subscription files located outside the default directory beyond removing the tool's reference to them (the original file is never deleted if it wasn't imported by copy).

**Exit codes:** `0` removed · `2` target is active · `3` not found.

---

## `mihomo sub refresh <name>`

```
mihomo sub refresh <name>
```

Remote-only; forces an out-of-cycle fetch ignoring the configured interval. Errors if called on a local subscription:
```
error: 'home-fiber' is a local subscription — refresh re-reads it automatically on 'sub use' (root cause: no remote source configured) (fix: use 'mihomo sub edit' to change the file, or re-import as remote)
```
Uses the fault-tolerant download path from §4.1.4 (resume-on-retry); a failed refresh leaves the previously cached copy untouched and does not affect an active subscription using it.

**Exit codes:** `0` success · `1` new content failed validation (old copy retained) · `2` called on a local subscription · `5` network error.

---

## `mihomo sub validate <name>`

```
mihomo sub validate <name>
```

Runs the same checks as the pre-switch validation in `sub use`, without activating. Useful for CI-style checks before committing to a switch. Prints the same structured error list as `sub add` on failure.

**Exit codes:** `0` valid · `1` invalid · `3` not found.
