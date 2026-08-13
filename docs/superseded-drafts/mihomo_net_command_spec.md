# `mihomo net` — Command Group Specification

Covers argument grammar, flags, output format, exit codes, and error message conventions for the network mode command group (§2.1, §2.3, §6.3 of the design doc). Follows the same conventions established in the `sub` group spec.

## Global conventions for this group

- All commands accept `--json`.
- All mutating commands (`system-proxy`, `tun`, `proxy-mode`) acquire the advisory lock (§3), run the atomic switch workflow (§4.1.1), and are mutually exclusive at the enforcement level: activating one automatically deactivates whichever of the three was previously active. There is no "all three off" state reachable via a single command — use `mihomo net off` for that.
- Error format and exit code table match the `sub` group spec, with two additions specific to this group:

| Code | Meaning |
|---|---|
| `6` | Privilege/entitlement error (Tun mode setup incomplete, sudo declined) |
| `7` | Port or interface unavailable |

---

## `mihomo net status`

```
mihomo net status [--json]
```

Shows current mode, target interface (System Proxy), port (Proxy Mode), or Tun interface name, plus whether the daemon (§2.3) is supervising it.

**Output (human):**
```
Mode:        System Proxy
Interface:   Wi-Fi (en0)
Since:       2026-08-12 09:14 (23m ago)
Supervised:  yes (launchd agent active)
```

If no mode is active:
```
Mode:        none
Note: traffic is not being proxied. Run 'mihomo net system-proxy on', 'net tun on', or 'net proxy-mode on'.
```

**Exit codes:** `0` always.

---

## `mihomo net system-proxy on|off`

```
mihomo net system-proxy on [--interface <service-name>] [--yes]
mihomo net system-proxy off
```

**`on` behavior (§2.1):**
1. Enumerates active network services via `networksetup -listallnetworkservices`, filters to ones currently carrying traffic (have a default route or active link).
2. If exactly one qualifies, targets it automatically and reports which one was chosen.
3. If more than one qualifies and `--interface` was not given, prompts:
   ```
   Multiple active network services found:
     1) Wi-Fi
     2) USB 10/100/1000 LAN
   Which should carry the proxy? [1-2]:
   ```
   Non-interactive contexts without `--interface` exit `1` with `error: multiple active interfaces — specify one with --interface`.
4. Before writing, checks whether a system proxy is already set on the target service by inspecting current `networksetup -getwebproxy <service>` state. If a proxy is already configured and doesn't match this tool's own last-known values, warns and requires confirmation:
   ```
   warning: a system proxy is already configured on 'Wi-Fi' (127.0.0.1:8118), possibly set by another application.
   Overwrite it? [y/N]
   ```
   `--yes` skips this prompt. Declining exits `2` with no changes made.
5. Applies HTTP/HTTPS proxy settings, verifies with a liveness check (a real request through the new proxy), and only then persists — rollback per §4.1.1 if the liveness check fails.

**`off` behavior:** Reverts only the settings this tool applied (tracked from step 5 above), not a blind proxy clear — so it won't stomp on a proxy another tool set up afterward. If the currently configured proxy doesn't match what this tool last set, warns before clearing:
```
warning: current system proxy on 'Wi-Fi' doesn't match what this tool configured — it may have been changed externally.
Clear it anyway? [y/N]
```

**Exit codes:** `0` success · `1` ambiguous interface, non-interactive · `2` conflict declined · `4` concurrent net operation in progress · `7` target interface has no active link.

---

## `mihomo net tun on|off`

```
mihomo net tun on [--yes]
mihomo net tun off
```

**`on` behavior:**
1. Checks whether the mihomo binary currently has the required network entitlement applied (§2.3). If not, this is first-time setup:
   ```
   Tun mode requires a one-time privileged setup step to grant network capability to the mihomo binary.
   This will prompt for your macOS password. Continue? [Y/n]
   ```
   Declining exits `6` with `error: Tun mode unavailable — entitlement setup declined`. Accepting runs the privileged step once; subsequent `tun on` calls don't re-prompt.
2. Pre-detects port/permission conflicts (§4.1.3): checks whether a Tun-style virtual interface already exists (e.g. from another VPN client) and whether the mihomo control port is free.
   ```
   error: cannot start Tun mode — utun interface already claimed, likely by another VPN client (fix: disconnect the other VPN and retry, or run 'mihomo net status' on it if it's a mihomo-managed instance)
   ```
3. Loads the virtual interface, verifies traffic is actually flowing through it (liveness check), then persists. Rollback on failure per §4.1.1, which also tears down the partially-created interface so no orphaned utun device is left behind.

**`off` behavior:** Tears down the virtual interface and reverts routing table changes. Idempotent — running `tun off` when Tun mode isn't active exits `0` with `Tun mode is not active — nothing to do.` rather than erroring.

**Exit codes:** `0` success · `4` concurrent net operation in progress · `6` entitlement setup declined or failed · `7` interface already claimed by another process.

---

## `mihomo net proxy-mode on|off`

```
mihomo net proxy-mode on [--port <port>]
mihomo net proxy-mode off
```

- `--port` default is the kernel's configured mixed-port (from the active subscription/config); explicit `--port` overrides it for this session only, without editing the subscription file (consistent with the no-file-mutation principle in §1.2.2 / §2.4).
- Pre-checks port availability before binding:
  ```
  error: cannot bind port 7890 — already in use by another process (pid 4021, 'com.docker.backend')
  ```
  (Process attribution via `lsof -i :<port>` where permissions allow; falls back to "in use by unknown process" if not resolvable without elevated privileges.)
- No system-level changes are needed for this mode (no `networksetup`, no privileged entitlement), so `on` has no `--yes`-gated conflict prompt — it either binds cleanly or fails with a port error.

**Exit codes:** `0` success · `4` concurrent net operation in progress · `7` requested port unavailable.

---

## `mihomo net off`

```
mihomo net off
```

Convenience command: deactivates whichever of System Proxy / Tun / Proxy Mode is currently active, equivalent to calling that mode's `off` subcommand. Idempotent if none is active.

**Exit codes:** `0` always (including no-op case).
