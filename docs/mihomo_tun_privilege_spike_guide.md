# Tun-Mode Privilege Mechanism — Prototype Spike Guide

Resolves requirement-closure item #1. This has now been run on the actual Mac Mini M4: unprivileged `utun` creation failed with `Operation not permitted`, while elevated creation through `sudo` succeeded and tore down cleanly. The confirmed implementation mechanism is `sudo`-elevated mihomo launch; the scoped NOPASSWD sudoers rule below is an optional daily-use convenience.

---

## 1. Why this needs root at all

Creating a `utun` virtual interface on macOS (what mihomo's Tun mode needs) isn't done through a normal socket call — it goes through the kernel's control-socket mechanism: `socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)`, then connecting to the `com.apple.net.utun_control` kernel control name. **That socket family is root-gated at the kernel level.** There is no `setcap`-style capability grant on macOS the way there is on Linux, and no per-binary entitlement that unlocks it for an unprivileged process talking to that specific control socket. Whatever mechanism this project settles on, the *actual* interface-creation call has to happen from a process running as root, full stop — the only open question is **how that root context gets established**, not whether it's needed.

## 2. Two viable mechanisms, compared

Given the confirmed scope (personal local use, single machine, no distribution, no Apple Developer Program requirement — see `CHANGELOG.md` entries §14–15), the heavier options (a proper Network Extension system extension, requiring notarized signing) are off the table. That leaves two realistic mechanisms:

| | **A. Sudoers NOPASSWD entry** | **B. Root `launchd` daemon** |
|---|---|---|
| **How it works** | `mihomo net tun on` shells out to `sudo <path-to-mihomo-kernel-binary> ...` for the Tun-enabled launch. A one-time-configured `/etc/sudoers.d/mihomo-cli` entry allows that exact binary path to run via `sudo` without a password prompt every time. | A `launchd` daemon (`RunAtLoad` or on-demand via `launchctl kickstart`) runs the mihomo kernel as root persistently; the CLI (running as your normal user) just starts/stops it via `launchctl`, never invoking `sudo` itself. |
| **Setup complexity** | Low — one `visudo` edit, done once. | Medium — need a root-owned plist in `/Library/LaunchDaemons/`, correct `chown root:wheel`/permissions, and `launchctl bootstrap system/...` instead of the user-agent pattern already used elsewhere in this project (§2.3 of the design doc). |
| **Fits existing design?** | Yes, cleanly — `net tun on/off` just becomes "invoke via sudo instead of directly," everything else (liveness check, rollback, atomic switch) stays identical. | Partial mismatch — this project's daemon design (`daemon install/remove/status`, §6.5) is a **user-level** agent for auto-restart supervision of the whole manager-launched process, not specifically for Tun privilege. Running the *whole* kernel as a system daemon just to get Tun would conflate two different concerns (privilege escalation vs. crash supervision) that are currently modeled as separate, orthogonal features. |
| **Recommendation** | **Preferred.** Simpler, matches the existing architecture exactly (Tun on/off stays a per-invocation choice, not an always-root-running background service), and is trivially reversible (`uninstall` just needs to remove one sudoers file). | Fallback only if (A) turns out to be blocked by something spike testing reveals (e.g. `sudo` behavior that doesn't fit non-interactive scripting well even with NOPASSWD, or a macOS 27 Beta-specific restriction on sudoers). |

**Working recommendation: Option A (sudoers NOPASSWD entry).** The rest of this guide validates that this actually works as expected before any Swift code gets written against it.

## 3. What the spike script tests

`scripts/tun_privilege_spike.sh` does not modify your system automatically — it only probes and reports, and prints exact manual commands for the one step (`visudo`) that's too risky to automate blindly. It:

1. Confirms you're running as your normal user, not already root (sanity check — the whole point is testing the *unprivileged→privileged* transition).
2. Attempts to create a `utun` interface **without** elevation, using a minimal C program compiled on the fly — expects this to fail with `Operation not permitted`, confirming the premise in §1.
3. Prints the exact `visudo` command and file content to add the NOPASSWD rule, **without applying it** — you run this step yourself since it edits system security policy.
4. After you've applied the sudoers rule (or if you want to test with plain interactive `sudo` first, before bothering with NOPASSWD), re-runs the same interface-creation test **with** `sudo` — expects this to succeed, prints the assigned `utunN` device name, then destroys it cleanly (`ifconfig utunN destroy`) so nothing is left behind.
5. If step 4 succeeds under `sudo` with the NOPASSWD rule applied, confirms no password prompt appeared (checks that the command completed without hanging on stdin).

## 4. How to run it

```
cd mihomo-cli-project-final
chmod +x scripts/tun_privilege_spike.sh
./scripts/tun_privilege_spike.sh
```

Read its output — it's designed to be self-explanatory and tells you exactly what passed, what failed, and what manual step (if any) to do next.

## 5. What the result means for implementation

- **If the spike passes end-to-end:** Option A is confirmed. The implementation for `net tun on` (Layer 6 / Phase 6) becomes: check whether the sudoers rule is already installed (test file existence + a `sudo -n <binary> --version`-style no-prompt check), install it via a **guided, explicit** one-time step if not (print the exact `visudo` instructions from this guide rather than silently calling `visudo` from Swift — modifying sudoers programmatically without the user directly reviewing the diff is exactly the kind of thing to avoid even for personal-use tooling), then launch the Tun-enabled kernel via `sudo <path> ...` from then on.
- **If interface creation fails even under `sudo`:** something more fundamental is wrong (missing entitlement even for root, a macOS 27 Beta regression, SIP interference) — stop and investigate before writing any Swift code; this would be a genuinely new finding worth logging in `CHANGELOG.md`.
- **If `sudo` works but the NOPASSWD rule doesn't suppress the password prompt:** fall back to interactive `sudo` (password prompt every `net tun on`, which is still acceptable for personal use, just less convenient) rather than debugging sudoers further, or reconsider Option B.

The observed outcome was the first case: Option A is confirmed. Implement `Support/TunPrivilege.swift` against `sudo`-elevated launch, with optional NOPASSWD detection and interactive `sudo` fallback.
