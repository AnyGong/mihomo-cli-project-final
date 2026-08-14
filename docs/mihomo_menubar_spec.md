# mihomo-menubar — macOS Menu Bar Icon Specification

**Status:** Final, authoritative for the menu bar companion app. **Read `AI.md` §1 first** — this document exists because of a deliberate, explicit exception to that section's "No GUI, ever" statement; see §0 below before assuming anything else in `AI.md` about distribution/packaging scope has also changed.

## 0. Scope-change note (read this first)

`AI.md` §1 states this project is "a pure command-line manager... No GUI, ever" and §3 convention #10 says not to add packaging/signing/versioning machinery. The user explicitly requested a macOS menu bar icon, which **is** a GUI element — this is a deliberate, one-time exception to the "No GUI, ever" line, not a reversal of the project's overall shape. Specifically, **only** the menu bar icon is in scope:

- No dashboard, no window, no settings pane belonging to this app itself. "Show Main Window" opens the *existing* mihomo dashboard at `http://127.0.0.1:9090` in the user's default browser — this app never renders that UI itself.
- Convention #10's "no packaging machinery" still holds: the menu bar app is a bare SwiftPM executable, not an `.app` bundle. No code signing, no Info.plist, no DMG/installer. See §3 for how "no Dock icon" and "Launch at Login" are achieved without one.
- All business logic (locking, atomic switching, rollback, liveness checks) stays exactly where it already is, inside `mihomo-cli`. The menu bar app is presentation-only — see §2.

If a future requirement conflicts with this narrow scope, update this section explicitly and log it in `CHANGELOG.md`, same rule as every other convention in `AI.md` §3.

## 1. Menu layout (source of truth — matches the user's requirements verbatim)

A persistent menu bar icon with:

1. **Show Main Window** — opens the default browser at `http://127.0.0.1:9090`.
2. **Outbound Mode** (submenu, single-select): Direct / Global / Rule.
3. **Set as System Proxy** (toggle, checkmark when enabled).
4. **Enhanced Mode (TUN mode)** (toggle, checkmark when enabled).
5. **Switch Configuration** (submenu, single-select) — populated dynamically from `mihomo sub list --json`, not hardcoded to `config1.yaml`/`config2.yaml`/`config3.yaml`; see §2.4 for why.
6. **Reload Configuration**.
7. **Launch at Login** (toggle).

## 2. Architecture

### 2.1 A second, independent executable target

`mihomo-menubar` is a second `.executableTarget` in the same `Package.swift`, alongside `mihomo-cli` (§Package.swift). It does **not** depend on the `mihomo-cli` target and imports no shared library between them. This is deliberate:

- Every menu action shells out to the already-built `mihomo-cli` binary (`Foundation.Process`), the same way a person would type it in a terminal. Locking (`AdvisoryLock`), the atomic switch workflow, rollback, and liveness checks all still run exactly once, inside the CLI process, so there is no risk of the GUI reimplementing (and subtly diverging from) tested behavior.
- The alternative — refactoring `mihomo-cli`'s single executable target into a shared library + thin CLI wrapper, so the menu bar app could call `ModeService`/`NetService`/`SubscriptionService` in-process — was rejected. It would touch every existing, tested file's target membership for a single-user local tool where subprocess latency (tens of milliseconds) is irrelevant, which is exactly the kind of speculative-generality cost AI.md §3's architecture principle warns against.

### 2.2 No Dock icon, no app bundle

`NSApp.setActivationPolicy(.accessory)` is set at runtime in `AppDelegate.applicationDidFinishLaunching`. This achieves "menu bar only, no Dock icon" without an `Info.plist` `LSUIElement` key, which would require an `.app` bundle — keeping this a bare `swift build` product, consistent with §0.

### 2.3 Binary discovery (`CLILocator`)

Resolution order: `MIHOMO_CLI_PATH` env var → a `mihomo-cli` binary next to the menu bar app's own executable (true whenever both were built by the same `swift build`, the expected setup) → `/usr/local/bin/mihomo-cli`. If none resolve, the menu shows a disabled "mihomo-cli not found" row instead of silently doing nothing.

### 2.4 State: polled, not owned

The menu bar app holds no persisted state of its own beyond the Launch-at-Login plist (§3). Every time the menu is about to open (`NSMenuDelegate.menuNeedsUpdate`) and on a 5-second timer otherwise, it runs three read commands concurrently and re-renders checkmarks from the result:

| Menu element | Source command | Field used |
|---|---|---|
| Outbound Mode checkmark | `mihomo mode status --json` | `effectiveMode` |
| Set as System Proxy checkmark | `mihomo net status --json` | `mode == "system-proxy"` |
| Enhanced Mode (TUN) checkmark | `mihomo net status --json` | `mode == "tun"` |
| Switch Configuration items + checkmark | `mihomo sub list --json` | `name`, `isActive` |
| Launch at Login checkmark | `LoginItemAgent.isEnabled` (local plist check, §3) | — |

This is why Switch Configuration is populated dynamically rather than hardcoded to `config1.yaml`/`config2.yaml`/`config3.yaml` as in the illustrative requirements text: the real source of truth is whatever subscriptions the user has actually imported via `mihomo sub add`, and hardcoding names would silently drift from it.

### 2.5 Action → command mapping

| Menu action | Command run | Notes |
|---|---|---|
| Show Main Window | *(none — opens browser directly)* | `NSWorkspace.shared.open(URL(string: "http://127.0.0.1:9090")!)`. Does not check kernel liveness first; if the kernel isn't running the browser will simply fail to connect, same as typing the URL manually. |
| Outbound Mode → Direct | `mihomo mode direct --yes` | `--yes` auto-confirms the behavior-change warning (§6.4 of the Full Specification) — appropriate here since the menu click *is* the user's explicit confirmation. |
| Outbound Mode → Global | `mihomo mode global --yes` | Same rationale. |
| Outbound Mode → Rule | `mihomo mode rule` | `rule` takes no `--yes` flag (no warning to suppress). |
| Set as System Proxy (on) | `mihomo net system-proxy on --yes` | `--yes` auto-confirms the "proxy already set by another app" overwrite warning. No `--interface`: if multiple active network services are ambiguous, this fails non-interactively (§net spec) and the failure is surfaced via an `NSAlert` with the CLI's own error text — the user can still resolve it from a terminal with `--interface`. |
| Set as System Proxy (off) | `mihomo net system-proxy off` | |
| Enhanced Mode (on) | `mihomo net tun on --yes` | `--yes` auto-confirms the one-time privileged entitlement prompt; macOS will still show its own password prompt for the underlying `sudo` step (§Tun privilege spike guide) — that's unavoidable and expected. |
| Enhanced Mode (off) | `mihomo net tun off` | |
| Switch Configuration → \<name\> | `mihomo sub use <name>` | No `--force`; if the switch is rejected (e.g. validation failure), the CLI's rollback message is shown verbatim in the alert. |
| Reload Configuration | `mihomo restart` | There is no dedicated "reload without restart" command (`docs/mihomo_api_reference_notes.md` notes `POST /restart` as a *possible future* lighter-weight primitive, not something built yet). `mihomo restart` is the existing, tested atomic stop/start of the kernel process, which re-reads the active subscription — that satisfies "Reload Configuration" today without inventing a new command. |
| Launch at Login (toggle) | *(none — local launchd agent, §3)* | |

Every action re-runs the §2.4 refresh after completion so checkmarks reflect what the CLI actually did (including a failed/rolled-back switch), not what the user clicked.

### 2.6 Failure reporting

`mihomo-cli` errors already follow `error: <what failed> — <root cause> (<suggested fix>)` (AI.md §3 convention #1). The menu bar app does not reformat or reinterpret this text — a failed action shows it verbatim in an `NSAlert`, titled `Couldn't <action>`.

## 3. Launch at Login

Implemented as a second, independent `launchd` agent, `~/Library/LaunchAgents/com.mihomo-cli.menubar.plist`, managed with the same `bootstrap`/`bootout` pattern already established and tested in `mihomo-cli`'s `Support/LaunchdAgent.swift` — not a new mechanism. Kept as a separate small type (`LoginItemAgent`) in the `mihomo-menubar` target rather than sharing code with `Support/LaunchdAgent.swift`, consistent with §2.1's "no shared target" decision, and functionally distinct from `com.mihomo-cli.agent.plist` (which supervises the *kernel* process with `KeepAlive`): this plist only sets `RunAtLoad`, no `KeepAlive` — quitting the menu bar app from its own Quit item must not cause it to be relaunched.

`ServiceManagement`'s `SMAppService` API was considered and rejected: it requires the executable to live inside a proper `.app` bundle's `Contents/MacOS/`, which would reintroduce the packaging machinery §0 explicitly rules out.

## 4. Build

```
cd mihomo-cli
swift build                       # builds both mihomo-cli and mihomo-menubar
swift run mihomo-menubar          # or: .build/debug/mihomo-menubar
```

For day-to-day use, run the built `mihomo-menubar` binary directly (or via the Launch at Login agent, §3) — there is intentionally no installer step per §0.

## 5. What's out of scope / not built here

- No settings/preferences UI — nothing in this app is user-configurable beyond what's in the menu itself. `MIHOMO_CLI_PATH` is an env var, not a UI toggle.
- No notifications (e.g. "switched to Global mode") — the menu's checkmarks are the confirmation; adding `NSUserNotification`/`UNUserNotificationCenter` was judged unnecessary chrome for a single-user tool and can be added later behind an explicit new instruction, per AI.md's general "don't add scope without being asked" stance.
- No handling of a `mihomo-cli` version mismatch between the two built binaries (e.g. `--json` shape changing). Both targets are built from the same package/commit, so this is not expected to occur in normal use.
