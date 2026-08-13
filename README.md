# mihomo-cli — Scaffold

Swift Package Manager scaffold for the pure-CLI mihomo kernel manager. Matches
the command surface, error format, and exit codes defined in the design specs:

- `AI.md` — **read this first.** Entry point, non-negotiable conventions, current status, and rules for continuing this project.
- `CHANGELOG.md` — chronological decision log.
- `docs/mihomo_CLI_Manager_Full_Specification.md` — design doc + full command reference (Appendix A)
- `docs/mihomo_control_api_integration_spec.md` — the KernelClient contract implemented in `mihomo-cli/Sources/mihomo-cli/KernelAPI/`
- `docs/mihomo_api_reference_notes.md` — real mihomo API field reference, already applied to `KernelClient.swift`
- `docs/mihomo_tun_privilege_spike_guide.md` + `scripts/tun_privilege_spike.sh` — documents the completed Tun-mode privilege spike. The mechanism is confirmed as `sudo`-elevated mihomo launch; the scoped sudoers NOPASSWD rule remains an optional convenience.

## Requirements to build

- Swift 5.9+ toolchain matching the Xcode/Swift version actually installed on the target machine (Mac Mini M4, macOS 27 Beta — see `Package.swift`, pinned to `.macOS("27.0")`)
- Verified on the target machine with Apple Swift 6.4 / macOS 27 SDK. In restricted Codex sandboxes, `--disable-sandbox` may be needed because SwiftPM's own sandbox can conflict with Codex's filesystem sandbox.

```
cd mihomo-cli
swift build
swift test --disable-sandbox
swift run mihomo-cli --help
```

## Layout

```
AI.md, CHANGELOG.md, README.md   <- you are here
docs/                             <- specs (see AI.md §2 for the full map)
mihomo-cli/                       <- the Swift package
  Package.swift
  Sources/mihomo-cli/
    MihomoCLI.swift              root command, wires up all subcommand groups
    MihomoCLIEntrypoint.swift    custom entrypoint for exact CLIError output/exit codes
    Commands/
      KernelCommand.swift        mihomo kernel ...   → docs/mihomo_CLI_Manager_Full_Specification.md Appendix A
      SubCommand.swift           mihomo sub ...       → same
      NetCommand.swift           mihomo net ...       → same
      ModeCommand.swift          mihomo mode ...      → same
      DaemonCommand.swift        mihomo daemon ...    → same
      LifecycleCommands.swift    start / stop / restart
    DiagnosticsCommands.swift  log / audit / doctor / uninstall
    KernelAPI/
      KernelClient.swift         protocol + URLSession HTTP client → docs/mihomo_control_api_integration_spec.md
    Support/
      ExitCode.swift             shared exit-code enum, matches every spec's table
      CLIError.swift             "error: <what> — <why> (<fix>)" formatter
      AdvisoryLock.swift         cross-invocation lock → design doc §3
      ResumableDownloader.swift  Range-resume helper for downloads
      ProcessController.swift    launch/stop/is-running wrapper for kernel processes
  Tests/mihomo-cliTests/
```

## Kernel provenance policy

Kernel binaries are fetched **only** via HTTPS directly against the official upstream mihomo GitHub releases API, matching the exact requested tag. There is **no local SHA256 verification** against a separately-published checksum — the official repository, reached over TLS, is the trust boundary. A download that doesn't resolve to a genuine official release asset (bad redirect, 404, malformed artifact) is refused and never registered. `kernel use`/`start`/`restart` still do an on-disk presence/intactness check (file exists, non-zero size) before launching, but this is not a cryptographic recheck. See design doc §4.1.3 for the full rationale.

## What's real vs. stubbed

**Real (implemented and testable):**
- Every command, subcommand, flag, and argument matches its spec exactly.
- The exit-code enum and error-message formatter (`Support/ExitCode.swift`, `Support/CLIError.swift`).
- `AdvisoryLock` — real `flock(2)`-based exclusive locking with non-blocking acquire, tested in `Tests/mihomo-cliTests/AdvisoryLockTests.swift`.
- `MetadataStore` — JSON-backed persistence for kernels, subscriptions, control-API credentials, and daemon state, using the temp-file-write + atomic-replace pattern from design doc §4.1.4. Tested in `Tests/mihomo-cliTests/MetadataStoreTests.swift`.
- `mihomo kernel list` and `mihomo sub list` — read from the real store and render the actual table/JSON output.
- `mihomo kernel fetch` — real GitHub Releases API integration for latest stable, latest 10 (`--all`), and explicit tags; selects the official upstream darwin-arm64 asset URL, downloads with resume/retry support, extracts `.gz`, marks the binary executable, and registers the kernel in the metadata store. Unit-tested and smoke-tested against the real upstream API with `v1.19.29`.
- `mihomo kernel use` — real kernel switch path with advisory locking, on-disk binary presence checks, fresh manager-owned control-API credentials/runtime config, previous-process stop/port-release handling, stdout/stderr capture, liveness retry/readback, running-state persistence, and rollback-failure reporting. Unit-tested and smoke-tested by live-switching between `v1.19.29` and `v1.19.28`.
- `mihomo kernel rm` — enforces the "cannot remove the active kernel" hard restriction (§1.1.2) against real store state; interactive TTY prompt via the shared `ConfirmationPrompt` helper; also deletes the kernel binary directory from disk on confirmation.
- `mihomo kernel check` — real update check: fetches latest stable metadata from the official GitHub Releases API (no download), compares against the active kernel, prompts to fetch+use as a combined atomic operation. Non-TTY without `--yes` fails closed per §3.12. Implemented and unit-tested (`KernelCheckServiceTests`).
- `mihomo kernel status` — real status display: queries `MetadataStore` for running kernel state, calls `KernelClient.version()` live to confirm API responsiveness, formats version/PID/uptime/API-health/supervision output in both human-table and `--json` modes. Implemented and unit-tested (`KernelStatusTests`).
- `HTTPKernelClient` — real `URLSession` calls for `/version`, `/configs` GET/PATCH, `/group`, `/proxies/{group}`, and `/connections`, with Bearer-token auth, short reachability preflight, HTTP status mapping to `CLIError`, and composed `livenessCheck`. Tested with mocked `URLProtocol` in `Tests/mihomo-cliTests/HTTPKernelClientTests.swift`.
- The executable entrypoint maps `CLIError` directly to the project's exact stderr format and custom exit-code table; this was live-regression-checked with active-kernel `kernel rm` returning exit `2`.
- `ConfirmationPrompt.confirm(_:yes:)` — shared TTY-detection helper used by `kernel check`, `kernel rm`, and future `mode global`/`direct` and `net` prompts. Fails closed (throws `CLIError` exit 1) in non-interactive/non-TTY contexts without `--yes`.
- `SubscriptionValidator` — full YAML syntax, parameter, proxy type, proxy group reference, rule-provider, and rule semantic validator using `Yams` with line-number extraction, tested in `Tests/mihomo-cliTests/SubscriptionValidatorTests.swift`.
- `mihomo sub add local` & `remote` — full validation before import, collision handling (prompts or appends `-2`, `-3`), Range-resumable remote download.
- `mihomo sub use` — atomic subscription switch with pre-flight validation, runtime configuration overlay generation, kernel liveness verification, rollback on failure, and mode precedence warning notes (§2.4).
- `mihomo sub edit` — active subscription guard (exit 2), `$EDITOR` execution, post-edit re-validation with `isFlaggedInvalid` flagging without reverting user files.
- `mihomo sub rm` — active subscription guard (exit 2), confirmation prompt, store and managed file cleanup.
- `mihomo sub refresh` — remote-only enforcement (exit 2 for local subs), fault-tolerant download, atomic update.
- `mihomo sub validate` — standalone validation command reporting structured errors with line numbers.
- `SubscriptionService` tested in `Tests/mihomo-cliTests/SubscriptionServiceTests.swift` including import safety tests verifying user files on disk are never mutated.
- `ModeService` — manages traffic rule mode (`mode status`, `mode rule`, `mode global`, `mode direct`) via control API `PATCH /configs` runtime overlays and `livenessCheck` readbacks, with safety confirmation prompts for Global/Direct modes and embedded subscription default comparisons. Tested in `Tests/mihomo-cliTests/ModeServiceTests.swift`.
- `NetService`, `NetworkSetup`, & `PortInspector` — manages macOS network routing modes (`net status`, `net system-proxy on|off`, `net tun on|off`, `net proxy-mode on|off`, `net off`) with mutual exclusivity, `networksetup` system proxy integration, port conflict detection via `lsof` with PID/process attribution, utun detection via `ifconfig`, and privilege safety handling. Tested in `Tests/mihomo-cliTests/NetServiceTests.swift` and `Tests/mihomo-cliTests/NetworkSetupTests.swift`.
- `DaemonService` & `LaunchdAgent` — manages `~/Library/LaunchAgents/com.mihomo-cli.agent.plist` for launchd supervision, crash detection, restart tracking, and persistence (`daemon install`, `daemon remove`, `daemon status`). Tested in `Tests/mihomo-cliTests/LaunchdAgentTests.swift`.
- `LifecycleService` — manual lifecycle controls (`start`, `stop`, `restart`) with user-initiated stop flagging for daemon supervision, integrity checks, liveness checks, and restart rollback. Tested in `Tests/mihomo-cliTests/LifecycleServiceTests.swift`.
- `AppLogger` — structured leveled logging (`info`, `warning`, `error`) with automatic size-based log rotation (5MB, 5 files) and immutable structured audit log recording (`audit.log`). Powers `log` and `audit` commands. Tested in `Tests/mihomo-cliTests/LoggerTests.swift`.
- `DoctorService` — dry-run pre-flight diagnostic suite verifying 7 subsystem checks (kernel binary, subscription validity, port availability, system proxy consistency, Tun entitlement, daemon health, disk/log headroom) in table or `--json` format without modifying state. Tested in `Tests/mihomo-cliTests/DoctorServiceTests.swift`.
- `UninstallService` — ordered, best-effort teardown (stop kernel -> remove launchd agent -> revert proxy -> net off -> optional `--purge-data`). Tested in `Tests/mihomo-cliTests/UninstallServiceTests.swift`.

## Implementation roadmap status

1. ~~`Support/` layer — `AdvisoryLock`, metadata store~~ **done.**
2. ~~`KernelClient` URLSession implementation + mocked unit tests~~ **done.** Live smoke confirmed `PATCH /configs {"mode":"global|direct|rule"}` returns 204 and reads back through `GET /configs`.
3. ~~**`kernel` group**~~ **done.** `fetch`, `use`, `check`, `status`, and `rm` are all implemented and verified.
4. ~~**`sub` group**~~ **done.** `SubscriptionValidator` (Yams-backed), `add`, `use`, `edit`, `rm`, `refresh`, and `validate` are fully implemented and unit-tested.
5. ~~**`mode` group**~~ **done.** `mode status`, `mode rule`, `mode global`, and `mode direct` are fully implemented and unit-tested.
6. ~~**`net` group**~~ **done.** `net status`, `net system-proxy`, `net tun`, `net proxy-mode`, and `net off` are fully implemented and unit-tested.
7. ~~**`daemon` + diagnostics**~~ **done.** `daemon install/remove/status`, `start/stop/restart`, `log`, `audit`, `doctor`, and `uninstall` are fully implemented and unit-tested.
