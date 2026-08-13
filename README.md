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
- `mihomo kernel rm` — enforces the "cannot remove the active kernel" hard restriction (§1.1.2) against real store state (interactive confirmation without `--yes` is still a stub).
- `HTTPKernelClient` — real `URLSession` calls for `/version`, `/configs` GET/PATCH, `/group`, `/proxies/{group}`, and `/connections`, with Bearer-token auth, short reachability preflight, HTTP status mapping to `CLIError`, and composed `livenessCheck`. Tested with mocked `URLProtocol` in `Tests/mihomo-cliTests/HTTPKernelClientTests.swift`.
- The executable entrypoint maps `CLIError` directly to the project's exact stderr format and custom exit-code table; this was live-regression-checked with active-kernel `kernel rm` returning exit `2`.

**Still stubbed:**
- `kernel check`/`kernel status` — no update-check or running-process status display logic yet.
- The whole `sub` group beyond `list` (validation, add, use, edit, refresh).
- `net`, `mode`, `daemon`, and diagnostics groups — no `networksetup`/`launchd` shelling or command-level control-API integration yet.
- A shared interactive-confirmation-prompt helper (`kernel rm` calls this out explicitly rather than duplicating ad hoc prompt code).
- `--sort` overrides in `kernel list`/`sub list` currently fall back to the spec's default sort regardless of the flag.

## Suggested implementation order (updated)

1. ~~`Support/` layer — `AdvisoryLock`, metadata store~~ **done.**
2. ~~`KernelClient` URLSession implementation + mocked unit tests~~ **done.** Live smoke confirmed `PATCH /configs {"mode":"global|direct|rule"}` returns 204 and reads back through `GET /configs`.
3. **Finish `kernel` group** — `fetch` and `use` are implemented; next are `check` and `status`, plus the remaining manual interrupted-download and forced-rollback checks.
4. **`sub` group** — YAML validation is the biggest chunk of new work here (rule semantic checks, param syntax).
5. **`mode` group** — thin once `KernelClient.patchConfigs` works; good early integration test of the liveness-check plumbing.
6. **`net` group** — save for last; the `networksetup`/sudo-elevated Tun/launchd shelling is the most macOS-specific and highest-risk code in the tool.
7. **`daemon` + diagnostics** — `doctor` in particular is easiest once the checks it composes (from steps 2–6) already exist independently.
