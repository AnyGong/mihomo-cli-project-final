# AI.md — mihomo-cli Project Handoff

**Read this file first, completely, before touching any code or spec in this repo.** It is the entry point for any AI assistant (or human) picking up this project. It does not replace the other documents — it tells you which ones exist, what order to read them in, and which rules across all of them are non-negotiable. If anything in this file appears to conflict with another document, **this file wins**, because it was written last and reflects the most current decisions.

---

## 1. What this project is

A pure command-line manager for the **mihomo** proxy kernel, for **personal local use on a single machine: a Mac Mini M4 running macOS 27 Beta.** No GUI, ever. No distribution, no other users, no support matrix — this is not a product being shipped to anyone, and every requirement-closure item that only mattered for distribution (code signing, distribution channel, the tool's own versioning policy, a broader macOS version floor, a license) has been explicitly canceled as not applicable. It manages: kernel binary versions, subscription (proxy config) files, network runtime mode (system proxy / Tun / port-based), and traffic rule mode (rule / global / direct) — entirely through terminal commands.

This is not a wrapper around an existing GUI client. It is a new, independent tool, implemented in **Swift** (Swift Package Manager, `swift-argument-parser`), chosen specifically because the platform scope is macOS-only and the tool needs to shell out to `networksetup`, `launchd`, and Tun-interface primitives natively.

## 2. Document map — read in this order

This package is laid out as:

```
AI.md                                    <- you are here
CHANGELOG.md
README.md                                <- build instructions, file layout, live status table
docs/
  mihomo_CLI_Manager_Full_Specification.md
  mihomo_Kernel_Pure_CLI_Manager_Design_Document_v2.md
  mihomo_control_api_integration_spec.md
  mihomo_implementation_test_verification_plan.md
  mihomo_requirement_development_plan.md
  mihomo_api_reference_notes.md
  mihomo_tun_privilege_spike_guide.md
  superseded-drafts/                     <- old per-group specs, kept for diff history only
scripts/
  tun_privilege_spike.sh                 <- run this on the Mac Mini to resolve open decision #1
mihomo-cli/                              <- the Swift Package Manager project itself
  Package.swift, Sources/, Tests/
```

| # | File | What it is | Status |
|---|---|---|---|
| 1 | **`AI.md`** (this file) | Entry point, rules, doc map, current status | — |
| 2 | `CHANGELOG.md` | Chronological log of every major decision and why it was made | — |
| 3 | `docs/mihomo_CLI_Manager_Full_Specification.md` | **The design spec.** Design doc §1–5 + command surface §6 + full command reference (Appendix A, all six command groups). This is the source of truth for *behavior* — every flag, prompt, error message, and exit code. | Final, authoritative |
| 4 | `docs/mihomo_control_api_integration_spec.md` | The `KernelClient` contract — how the CLI talks to the running mihomo kernel's REST control API. Defines `livenessCheck` precisely, which every atomic switch in the whole tool depends on. | Final, authoritative |
| 5 | `docs/mihomo_implementation_test_verification_plan.md` | Layer-by-layer (`KernelClient` → `kernel` → `sub` → `mode` → `net` → `daemon`/diagnostics) implementation scheme, test plan, and verification checklist for everything not yet built. | Final, authoritative — **follow this as the build order** |
| 5b | `docs/mihomo_requirement_development_plan.md` | Project-management layer above the implementation plan: a requirement-closure register (open questions not yet answered anywhere else, e.g. code signing, distribution channel, telemetry stance) plus a phased deliverables list (Phase 0–9) with exit criteria per phase. **Read this to know what to build next and what still needs a decision before building it.** | Final, authoritative |
| 5c | `docs/mihomo_api_reference_notes.md` | Official mihomo control-API endpoint reference (sourced from mihomo's own docs, not general Clash-API memory), mapped to which command uses which endpoint, with a concrete code-correction checklist already applied to `KernelClient.swift`. Requirement-closure item #2 is now closed by live smoke testing against a running mihomo instance. | Final, live-confirmed for this project's current endpoint use |
| 5d | `docs/mihomo_tun_privilege_spike_guide.md` + `scripts/tun_privilege_spike.sh` | Resolves requirement-closure item #1: the hardware spike confirmed that `utun` creation requires elevation and that `sudo`-elevated mihomo launch works on the Mac Mini. The guide's scoped `sudoers.d` NOPASSWD rule remains an optional daily-use convenience, not a blocker. | Final, hardware-confirmed |
| 6 | `docs/mihomo_Kernel_Pure_CLI_Manager_Design_Document_v2.md` | The revised original design document (§1–5) that the Full Specification is built on top of. | Superseded by #3 for behavior detail, but useful for the narrative "why does this section exist" framing |
| 7 | `README.md` | Build instructions, file layout, and a live "what's real vs. stubbed" status table. Lives at the package root, not inside `mihomo-cli/` — see entry 16 in `CHANGELOG.md` for why. | **Update this every time you implement something** — it is the fastest way for the next assistant (or human) to know current state without re-reading this whole file |

The five files under `docs/superseded-drafts/` (`sub`, `net`, `kernel`, `mode`, `daemon_lifecycle_diagnostics` command specs) were the original per-group drafts. **They have been superseded by and merged into `docs/mihomo_CLI_Manager_Full_Specification.md` Appendix A.** They're kept for edit history / diffing convenience only — always treat the Full Specification as authoritative if the two ever disagree (they shouldn't; the merge was verbatim, but future edits should land in the Full Specification, not the standalone files, to avoid drift).

## 3. Non-negotiable conventions (apply to every command, every layer)

These were established deliberately across the design review and must not be silently changed. If a future requirement genuinely conflicts with one of these, **update the spec docs explicitly and note it in `CHANGELOG.md`** — do not let code and docs drift apart.

1. **Error message format**: `error: <what failed> — <root cause> (<suggested fix>)`. The `fix` clause is optional; the em-dash separator and the format is not.
2. **Exit code table is global**, not per-command (see `Support/ExitCode.swift` for the canonical Swift enum):
   `0` success · `1` validation failure · `2` permission/state denied · `3` not found · `4` conflict (lock contention / name collision) · `5` network error · `6` privilege/entitlement error (net group) · `7` port/interface unavailable (net group) · `8` source verification / binary presence failure (kernel group) · `130` interrupted (Ctrl-C).
3. **Kernel provenance policy — no local SHA256 verification.** This was explicitly cancelled by the user. Kernel binaries are trusted based on being fetched *directly, over HTTPS, from the official upstream mihomo GitHub releases API* for the exact requested tag. If a download doesn't resolve to a genuine official release asset, refuse it. Do not reintroduce checksum verification without an explicit new instruction — this was a deliberate simplification, not an oversight. `kernel use`/`start`/`restart` still do a lightweight on-disk presence/intactness check (file exists, non-zero size) before launch — that's a sanity check, not a cryptographic one, and should not be confused with the removed SHA256 step.
4. **Never mutate a user's original subscription file.** Mode overrides, kernel-visible config changes, etc. are applied as a runtime overlay via the kernel's control API (`PATCH /configs`), never by editing the subscription YAML on disk. This was added specifically to close a review-flagged risk — preserve it.
5. **The active kernel and active subscription are locked** against deletion, modification, and hot-swap, with no override flag that bypasses this. `--force` flags in this codebase are documented, narrow exceptions (e.g. skipping a compatibility *warning*, never skipping a *hard restriction* or an integrity/presence check).
6. **Every config-mutating command acquires `AdvisoryLock`** before touching anything (cross-*process* concurrency guard, real `flock(2)`, already implemented in `Support/AdvisoryLock.swift`). This is separate from and in addition to whatever intra-process async safety a component needs (e.g. `MetadataStore` is an `actor`).
7. **Atomic switch pattern** for every state-changing operation (`kernel use`, `sub use`, `net *`, `mode *`): backup current state → validate/pre-check → apply → **liveness check** (defined precisely in the control-API integration spec §4) → persist. Any failure at any step rolls back to the prior state and reports which stage failed, in the message format from convention #1.
8. **All config/metadata file writes use temp-file-write + atomic-rename**, never a direct overwrite. Already implemented in `Support/MetadataStore.swift` — follow that pattern for any new persisted state.
9. **`--json` on every read command**, for scriptability. Already established in every stub; don't drop it when implementing.
10. **macOS/Apple Silicon only — and more specifically, one machine.** Do not add cross-platform abstraction layers "for future flexibility," and do not add distribution/compatibility-matrix concerns either — this is confirmed personal local-use tooling for a single machine (Mac Mini M4, macOS 27 Beta), not a distributed product. `Package.swift`'s platform floor is pinned to `.macOS("27.0")` to match exactly, not a conservative "Ventura+" guess. Speculative generality here is wasted complexity per this project's own architecture principles (§5 of the design doc: high cohesion, low coupling, but *not* speculative generality) — this now extends to not building any packaging, signing, versioning, or multi-version-support machinery either, since none of it will ever be exercised.
11. **No telemetry, ever.** This tool sends nothing about the user, their subscriptions, their kernel versions, or their usage to anywhere except: (a) the official mihomo GitHub releases API, strictly to fetch a binary the user explicitly requested, and (b) whatever remote URL the user themselves configured for a remote subscription. No analytics, crash reporting, or "phone home" update-check beacon of any kind. This is a stated guarantee, not an implementation gap — do not add any telemetry mechanism without an explicit, separate instruction to do so, and if one is ever added, it must be opt-in and disclosed in `README.md`, not silently bundled.
12. **Non-interactive / non-TTY output policy.** Every command with an interactive confirmation prompt (`[y/N]`-style) must detect a non-interactive context (stdout/stdin not a TTY, e.g. piped output, run from a script or CI) and **fail closed** rather than hang: if `--yes` wasn't passed, exit immediately with a validation-failure-style error explaining that the operation requires either an interactive terminal or `--yes`. Never block indefinitely on `readLine()` waiting for input that will never arrive. This applies uniformly across every group with a prompt (`kernel rm`, `kernel check`, `sub add`/`use`/`rm`, `net system-proxy on`/`tun on`, `mode global`/`direct`, `daemon install`/`remove`, `uninstall`) — implement the TTY check once as a shared helper (the same shared confirmation-prompt helper already planned for Phase 5 of the requirement development plan) rather than duplicating the check per command.
13. **English-only output.** All user-facing text — error messages, prompts, `--help` output, table headers, status text — is English only. No localization/i18n architecture (string tables, locale lookup, etc.) should be introduced. This was an open question (requirement-closure register item #7) resolved explicitly by the user; do not add multi-language support without a new, explicit instruction to do so.

## 4. Complete requirement history (condensed)

Full detail is in `CHANGELOG.md`; this is the condensed version so you don't have to read a transcript to get the gist.

1. User supplied an initial Chinese/English design doc for a pure-CLI mihomo manager on macOS Apple Silicon: kernel version management, subscription management, network mode switching, rule mode switching, plus stability guarantees (atomic changes, rollback, process supervision, multi-layer validation, fault-tolerant I/O, audit logging).
2. A design review surfaced 8 gaps: unspecified macOS system integration mechanics, undefined precedence between CLI mode switches and subscription-embedded mode, confusing "Always" refresh-interval labeling, an arbitrary 10-release fetch cap with no pinning fallback, no conflict handling when another app already owns the system proxy, no uninstall/teardown story, no audit log rotation policy, no cross-invocation concurrency handling.
3. All 8 gaps were resolved and written into a v2 design doc as new subsections (§2.3 macOS System Integration, §2.4 Mode Precedence, §2.5 Teardown/Uninstall, §4.1.6 Audit Log Retention, concurrency locking in §3, version pinning in §1.1.3, refresh-behavior relabeling in §1.2.1, proxy-conflict detection in §2.1).
4. A full command surface was sketched (§6) and then expanded into detailed per-group specs (flags, prompts, exit codes, error text) for all six groups: `sub`, `net`, `kernel`, `mode`, `daemon`, lifecycle/diagnostics.
5. All specs were consolidated into one Full Specification document, plus a separate control-API integration spec defining exactly how the tool talks to the running mihomo kernel (endpoints used, auth/secret handling, the precise definition of "liveness check").
6. A Swift Package Manager project was scaffolded end-to-end: every command/subcommand/flag from the spec, wired through `swift-argument-parser`, with all business logic stubbed as "not implemented" errors. **No Swift toolchain was available in the authoring sandbox — none of this has been compiled or run.** This must happen on a real Mac before anything else.
7. User explicitly **cancelled the SHA256 kernel-verification plan** and directed that the official upstream repository (reached over HTTPS) be the trust standard instead. This was propagated through every spec document and the scaffold's code comments — see convention #3 above.
8. The Support layer was implemented for real (not stubbed): `AdvisoryLock` (real `flock(2)`), `MetadataStore` (JSON-backed, atomic writes, actor-isolated), plus `kernel list`, `sub list`, and `kernel rm`'s active-kernel guard wired to real store data. Unit tests exist for both `AdvisoryLock` and `MetadataStore`.
9. A full implementation/test/verification plan was written for every remaining layer (`KernelClient` HTTP implementation, then `kernel`/`sub`/`mode`/`net`/`daemon`+diagnostics groups), including flagged open design decisions (notably: the exact macOS mechanism for Tun-mode privilege escalation needs a hardware prototype/spike, not a guess from documentation).
10. This file (`AI.md`) and `CHANGELOG.md` were written to hand the project to other AI tooling without losing any of the above.

## 5. Current implementation status (snapshot — verify against `README.md` for the live version)

**All 7 layers are fully implemented, tested, and real:**
- `Support/ExitCode.swift`, `Support/CLIError.swift` — centralized exit codes and standard error formatting.
- `MihomoCLIEntrypoint.swift` — custom ArgumentParser entrypoint ensuring thrown `CLIError`s print `error: <what> — <cause> (<fix>)` and exit with the designated code.
- `Support/AdvisoryLock.swift` — cross-process `flock(2)` advisory lock with automatic release on failure. Tested (`Tests/mihomo-cliTests/AdvisoryLockTests.swift`).
- `Support/Models.swift`, `Support/MetadataStore.swift` — JSON-backed metadata store (kernels, subscriptions, control-API credentials, daemon state, network mode, last applied system proxy) with defensive backward-compatible decoding and atomic temp-file-and-rename writes. Tested (`Tests/mihomo-cliTests/MetadataStoreTests.swift`).
- `Support/ConfirmationPrompt.swift` — shared TTY-detection helper failing closed in non-interactive/piped environments without `--yes`.
- `KernelClient` / `HTTPKernelClient` — real `URLSession` implementation for the mihomo REST control API (`/version`, `/configs`, `/group`, `/proxies/{group}`, `/connections`, `livenessCheck`). Tested (`Tests/mihomo-cliTests/HTTPKernelClientTests.swift`).
- **`kernel` command group** ([`KernelCommand.swift`](file:///Users/john/Downloads/mihomo-cli-project-final/mihomo-cli/Sources/mihomo-cli/Commands/KernelCommand.swift)):
  - `kernel list` — human-formatted table and `--json` outputs with default sort (Active > Last Used > Version > Added Time).
  - `kernel fetch` — downloads official GitHub release tarballs with Range resume/retry, extracts `.gz`, verifies permissions, registers in store. Tested (`KernelFetchTests.swift`).
  - `kernel use` — atomic kernel switch with advisory locking, no-op check, binary integrity check, runtime config generation, intentional stop signaling, port release wait, liveness readback, and rollback. Tested (`KernelUseServiceTests.swift`).
  - `kernel check` — GitHub release checking, comparison against active kernel, interactive prompt, atomic switch. Tested (`KernelCheckServiceTests.swift`).
  - `kernel status` — runtime state inspection (version, PID, uptime, control API health, launchd supervision). Tested (`KernelStatusTests.swift`).
  - `kernel rm` — active kernel deletion protection (exit 2), interactive confirmation prompt, disk & metadata cleanup.
- **`sub` command group** ([`SubCommand.swift`](file:///Users/john/Downloads/mihomo-cli-project-final/mihomo-cli/Sources/mihomo-cli/Commands/SubCommand.swift)):
  - `SubscriptionValidator` — AST-based multi-layer validator using `Yams` (syntax, structure, proxy types, proxy group targets, rule providers, rule semantic resolution) reporting exact line numbers. Tested (`SubscriptionValidatorTests.swift`).
  - `SubscriptionService` — `add local` (file safety preserved, never mutates user source files), `add remote` (Range-resumable download), `use` (atomic switch with runtime config overlay generation and mode precedence note comparison), `edit` (active guard exit 2, `$EDITOR` spawn, `isFlaggedInvalid` flagging without reverting edits), `rm` (active guard exit 2, prompt, cleanup), `refresh` (remote-only guard exit 2, download, reload), and `validate` (line-number diagnostics). Tested (`SubscriptionServiceTests.swift`).
- **`mode` command group** ([`ModeCommand.swift`](file:///Users/john/Downloads/mihomo-cli-project-final/mihomo-cli/Sources/mihomo-cli/Commands/ModeCommand.swift)):
  - `ModeService` — `mode status` (compares live kernel mode with subscription embedded default, reporting matches vs. CLI overrides), `mode rule`, `mode global` (safety confirmation prompt, exit 2 on decline), and `mode direct` (safety confirmation prompt, exit 2 on decline) using runtime `PATCH /configs` overlays and `livenessCheck` readbacks. Tested (`ModeServiceTests.swift`).
- **`net` command group** ([`NetCommand.swift`](file:///Users/john/Downloads/mihomo-cli-project-final/mihomo-cli/Sources/mihomo-cli/Commands/NetCommand.swift)):
  - `NetworkSetup` — testable wrapper around macOS `/usr/sbin/networksetup` managing service enumeration, active IP link detection, and web proxy configuration. Tested (`NetworkSetupTests.swift`).
  - `PortInspector` — testable wrapper around `/usr/sbin/lsof` (for TCP LISTEN port checking with process PID/name attribution) and `/sbin/ifconfig -a` (for `utun` conflict detection — requires `UP` **and** a non-link-local address, not name-presence alone; see CHANGELOG #27, a real-hardware false-positive fix). Tested (`PortInspectorTests.swift`).
  - `NetService` — `net status` (table / `--json`), `net system-proxy on|off` (single service auto-selection, multiple active services prompt vs `--interface`, pre-existing foreign proxy overwrite warning/prompt), `net tun on|off` (privilege elevation verification exit 6, utun collision exit 7), `net proxy-mode on|off` (port conflict check exit 7), and `net off` (idempotent deactivation). Enforces mutual exclusivity across all modes. Tested (`NetServiceTests.swift`).
- **`daemon` command group** ([`DaemonCommand.swift`](file:///Users/john/Downloads/mihomo-cli-project-final/mihomo-cli/Sources/mihomo-cli/Commands/DaemonCommand.swift)):
  - `DaemonService` & `LaunchdAgent` — manages `~/Library/LaunchAgents/com.mihomo-cli.agent.plist` generation, `launchctl bootstrap`/`bootout`, and `MetadataStore` supervision state tracking (`daemon install`, `daemon remove`, `daemon status`). Tested (`LaunchdAgentTests.swift`).
- **Lifecycle commands** ([`LifecycleCommands.swift`](file:///Users/john/Downloads/mihomo-cli-project-final/mihomo-cli/Sources/mihomo-cli/Commands/LifecycleCommands.swift)):
  - `LifecycleService` — `start` (binary presence check exit 8, already-running guard exit 2, process spawn, control API liveness check, observed start marking), `stop` (not-running guard exit 2, `markKernelStopExpected()` flag setting to prevent auto-restart races, SIGTERM/SIGKILL), `restart` (atomic stop and start with rollback). Tested (`LifecycleServiceTests.swift`).
- **Diagnostics commands** ([`DiagnosticsCommands.swift`](file:///Users/john/Downloads/mihomo-cli-project-final/mihomo-cli/Sources/mihomo-cli/Commands/DiagnosticsCommands.swift)):
  - `AppLogger` — structured leveled logger (`info`, `warning`, `error`) supporting automatic size-based log rotation (5MB, up to 5 historical files) and immutable structured audit log engine (`audit.log`) queryable with `--since` and `--action`. Powers `log` and `audit`. Tested (`LoggerTests.swift`).
  - `DoctorService` — dry-run diagnostic suite verifying 7 subsystem checks (kernel binary presence, subscription validity, port availability, system proxy consistency, Tun entitlement, daemon health, disk/log headroom) in table or `--json` format without modifying state. Tested (`DoctorServiceTests.swift`).
  - `UninstallService` — ordered, best-effort teardown (stop kernel -> remove daemon -> revert proxy -> net off -> optional `--purge-data`). Tested (`UninstallServiceTests.swift`).

**Verified to compile/test:**
- `swift test --disable-sandbox` executed on 2026-08-14: **127 XCTest unit tests, 0 failures** (Apple Swift 6.4, macOS 27 SDK).
- `CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" SWIFTPM_CACHE_PATH="$PWD/.build/swiftpm-cache" swift test --disable-sandbox` is the standard test command.

## 6. Verification checklist and release gate

All software layers are built and covered with comprehensive automated unit tests. The final phase is **manual hardware verification** on the physical Mac Mini M4 running macOS 27 Beta, per `docs/mihomo_implementation_test_verification_plan.md`:

1. **Kernel Group**:
   - [ ] Interrupted-download resume: `kernel fetch` with mid-download kill, confirm re-run resumes from where it stopped.
   - [ ] Forced rollback: `kernel use` with the new process SIGSTOPped mid-liveness-check — confirm timeout and rollback to previous version rather than hanging.
2. **Sub Group**:
   - [ ] Import real subscription files, verify proxy groups, and test atomic switch under traffic.
3. **Mode Group**:
   - [ ] Confirm `mode global`'s LAN-access warning text renders accurately and prompts as specified.
4. **Net Group**:
   - [ ] Multi-interface system-proxy: confirm prompt displays real network services and applies proxy in macOS System Settings.
   - [ ] Tun mode: verify `sudo`-elevated launch on real hardware, check `utun` interface creation and routing, verify teardown leaves no orphaned `utun` devices.
   - [x] ~~`net tun on` always failed with "utun interface already claimed" on real hardware, even with nothing running~~ **root-caused and fixed (see CHANGELOG #27):** `isUtunInterfacePresent()` checked interface *name* presence only, which macOS pre-allocates for its own frameworks on every Mac; now requires `UP` + a real (non-link-local) address. Unit-tested against captured `ifconfig -a` shapes. **Still needs a real re-run of `net tun on` on the Mac Mini** — not yet re-verified on hardware, only reasoned + unit-tested.
   - [ ] Follow-up noted in CHANGELOG #27, not yet actioned: `kernel use <already-active>`'s no-op fast path trusts the stored active-kernel pointer without checking whether a process is actually alive (unlike `kernel status`, which does check). Reconcile the two before relying on `kernel use`'s no-op path as a liveness signal.
5. **Daemon & Lifecycle**:
   - [ ] `daemon install`, then force-kill kernel (`kill -9`) — confirm `launchd` auto-restarts it and increments restart count in `daemon status`.
   - [ ] `mihomo stop` while daemon is installed — confirm it does **not** auto-restart (user-initiated stop contract).
   - [ ] `mihomo doctor` — verify diagnostic report against live system.
   - [ ] `mihomo uninstall --purge-data` — verify complete system restoration and clean data removal.

## 7. Rules for whoever (or whatever) works on this next

- **Update `README.md`'s status table every time you modify anything.**
- **Update `CHANGELOG.md`** with any decision that changes behavior, conventions, or scope.
- **Do not modify the non-negotiable conventions in §3** without updating every document that references them (`Full Specification`, `control_api_integration_spec`, this file).
- **Keep `swift test` green after every modification.** (Run with `--disable-sandbox`).
- **Release Gate**: The tool is considered release-ready when all manual hardware verification checkboxes above are confirmed on the physical Mac Mini M4.

