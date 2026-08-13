# `mihomo mode` — Command Group Specification

Covers argument grammar, flags, output format, exit codes, and error message conventions for the rule mode command group (§2.2, §2.4, §6.4 of the design doc). Follows the same conventions established in the `sub`, `net`, and `kernel` group specs.

## Global conventions for this group

- All commands accept `--json`.
- All mutating commands (`rule`, `global`, `direct`) acquire the advisory lock (§3).
- This group is simpler than `net`: switching rule mode is an in-process call to the running kernel's control API (no `networksetup`, no privileged entitlement, no virtual interfaces), so there's no equivalent of `net`'s `--interface`/entitlement machinery. It reuses the base exit code table from the `sub` spec with no additions.
- All three mutating commands require a kernel to be running; if not, they fail immediately rather than attempting a switch:
  ```
  error: no kernel running — cannot change rule mode (fix: run 'mihomo start' first)
  ```
  Exit code `2` (permission/state denied) for this case, consistent with other "operation not valid in current state" errors.

---

## `mihomo mode status`

```
mihomo mode status [--json]
```

Shows the mode currently in effect and, per §2.4, flags any mismatch against the active subscription's embedded default.

**Output (human), matching case:**
```
Effective mode:  rule
Subscription default: rule (matches)
```

**Output (human), overridden case:**
```
Effective mode:  global
Subscription default: rule (CLI override in effect)
Note: this override was applied via 'mihomo mode global' and persists until changed or the subscription is switched.
```

If no subscription is active, `Subscription default` is omitted and replaced with `No active subscription — mode is a kernel-level setting only.`

**Exit codes:** `0` always.

---

## `mihomo mode rule`

```
mihomo mode rule
```

Applies Rule Mode as a runtime overlay (§2.4) — routes per the active subscription's rule list. This is the default mode and also serves as "clear the override," since it's the same value most subscriptions embed:

```
✅ Rule mode active.
```

If the subscription's embedded default is *not* `rule`, this counts as a CLI override just like `global`/`direct`, and `mode status` will report it as such afterward.

**Exit codes:** `0` success · `2` no kernel running · `4` concurrent mode operation in progress.

---

## `mihomo mode global`

```
mihomo mode global [--yes]
```

Forces all traffic through the proxy tunnel, overriding the subscription's rule list. Because this is a significant behavior change (things like LAN-local traffic or captive portals can break under Global Mode), it prompts for confirmation unless `--yes`:

```
Global Mode forces ALL traffic through the proxy, bypassing your subscription's rule list. This can affect LAN access and some captive portals.
Continue? [y/N]
```

**Exit codes:** `0` success · `2` no kernel running, or declined confirmation · `4` concurrent mode operation in progress.

---

## `mihomo mode direct`

```
mihomo mode direct [--yes]
```

Forwards all traffic locally without passing through the mihomo kernel — effectively a proxy bypass while leaving the kernel running. Same confirmation gate as `global`, since this silently stops protecting/routing all traffic:

```
Direct Mode sends ALL traffic locally, bypassing the proxy entirely. Nothing will be routed through mihomo until you switch modes again.
Continue? [y/N]
```

**Exit codes:** `0` success · `2` no kernel running, or declined confirmation · `4` concurrent mode operation in progress.
