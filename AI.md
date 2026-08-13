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

**Fully implemented, tested, real:**
- `Support/ExitCode.swift`, `Support/CLIError.swift` — exit codes and error formatting.
- `MihomoCLIEntrypoint.swift` — custom ArgumentParser entrypoint so thrown `CLIError`s print the spec's exact `error: ...` format and exit with the project's custom exit-code table.
- `Support/AdvisoryLock.swift` — real `flock(2)` locking. Tested (`Tests/mihomo-cliTests/AdvisoryLockTests.swift`).
- `Support/Models.swift`, `Support/MetadataStore.swift` — JSON-backed metadata store (kernels, subscriptions, control-API credentials, daemon state) with atomic writes. Tested (`Tests/mihomo-cliTests/MetadataStoreTests.swift`).
- `mihomo kernel list` — real data, real table/JSON output.
- `mihomo sub list` — real data, real table/JSON output.
- `mihomo kernel fetch` — real official GitHub Releases API path for latest stable, latest 10 (`--all`), and explicit tags. It selects the upstream-provided darwin-arm64 asset URL (never constructs one by hand), downloads with Range resume/retry, extracts the `.gz`, sets executable permissions, and registers the kernel in `MetadataStore`. Unit-tested and smoke-tested against upstream by downloading `v1.19.29` and `v1.19.28`.
- `mihomo kernel use` — real atomic-ish kernel switch path with advisory locking, pre-lock and post-lock no-op checks, on-disk binary presence check, fresh manager-owned control-API credentials/runtime config, intentional stop marking for the previous running process, port-release wait, subprocess stdout/stderr capture, liveness retry/readback, active/running metadata persistence, and distinct rollback-failure reporting. Unit-tested and smoke-tested by switching live between `v1.19.29` and `v1.19.28`.
- `mihomo kernel rm` — enforces the active-kernel hard restriction against real store state. (Its `--yes`-less interactive confirmation path is still a stub — see below.)
- `KernelClient` / `HTTPKernelClient` — real `URLSession` implementation for the mihomo control API: Bearer-token auth, short `/version` reachability preflight, `/configs` GET/PATCH, `/group` policy-group reads, reserved `/proxies/{group}` node selection, `/connections` GET/DELETE, HTTP status/error mapping, and the composed `livenessCheck`. Tested with mocked `URLProtocol` (`Tests/mihomo-cliTests/HTTPKernelClientTests.swift`).

**Command grammar complete, behavior stubbed** (every flag/arg/subcommand exists and parses correctly; `run()` throws "not implemented"):
- `kernel check`, `kernel status`
- `sub add` (local + remote), `sub use`, `sub edit`, `sub rm`, `sub refresh`, `sub validate`
- entire `net` group (`status`, `system-proxy`, `tun`, `proxy-mode`, `off`)
- entire `mode` group (`status`, `rule`, `global`, `direct`)
- entire `daemon` group (`install`, `remove`, `status`)
- `start`, `stop`, `restart`, `log`, `audit`, `doctor`, `uninstall`

**Not started at all:**
- YAML subscription validation (`SubscriptionValidator` — doesn't exist yet)
- `networksetup` wrapper (`Support/NetworkSetup.swift` — doesn't exist yet)
- Tun-mode Swift integration (`Support/TunPrivilege.swift` — doesn't exist yet; hardware spike resolved the mechanism as `sudo`-elevated launch)
- `launchd` plist generation (`Support/LaunchdAgent.swift` — doesn't exist yet)
- Leveled/rotating logger (`Support/Logger.swift` — doesn't exist yet; every stub currently just throws, nothing calls a logger)
- Shared interactive-confirmation-prompt helper (currently duplicated informally / stubbed per-command)

**Verified to compile/test:** `swift test --disable-sandbox` passed on 2026-08-13 with 40 XCTest tests (Apple Swift 6.4, macOS 27 SDK). `--disable-sandbox` was needed in the Codex sandbox because SwiftPM's own sandbox conflicted with Codex's filesystem sandbox; normal network access is available again. **Manual/live mihomo QA is partially complete:** `kernel fetch` has been smoke-tested against the real upstream GitHub API and produced working `v1.19.29` and `v1.19.28` arm64 binaries; `kernel use` has live-switched between them; `/version` and `PATCH /configs {"mode":"global|direct|rule"}` were confirmed against a running mihomo instance; active-kernel `kernel rm` blocking was rechecked with exact stderr and exit code `2`.

## 6. Immediate next task and known open decisions

Per `mihomo_implementation_test_verification_plan.md`, the next layer is still **finishing the `kernel` command group** (Layer 3). `kernel fetch` and `kernel use` are implemented; next are `kernel check` and `kernel status`, plus the remaining manual Layer 3 checks: interrupted-download resume and forced rollback under a deliberately stuck/failed new process.

Items previously flagged as **requiring a decision or a prototype spike on real hardware**, not something to implement from documentation alone:
1. ~~Tun-mode privilege escalation mechanism~~ **RESOLVED, confirmed on hardware (2026-08-13).** `scripts/tun_privilege_spike.sh` was run on the Mac Mini M4: unprivileged `utun` creation failed with `Operation not permitted` as expected, confirming root is genuinely required; elevated creation via `sudo` succeeded, producing a working `utun5` interface, cleanly torn down afterward. **Mechanism confirmed: `sudo`-elevated launch of the mihomo kernel binary.** The NOPASSWD `sudoers.d` convenience rule from the guide has **not** been applied yet — testing so far used plain interactive `sudo` (password prompt each time). This is not a blocker: `Support/TunPrivilege.swift` (Phase 6) should detect whether the NOPASSWD rule is present and fall back to interactive `sudo` gracefully if not, exactly as the guide's own fallback path already describes — applying the NOPASSWD rule for daily-use convenience can happen anytime, independently of implementation work.
2. ~~mihomo's actual `/configs` and `/proxies` response schemas~~ **RESOLVED, live-confirmed (2026-08-13).** `docs/mihomo_api_reference_notes.md` documents the current mihomo API, and `HTTPKernelClient` uses the corrected shapes (`/group` instead of `/proxies` for policy groups, kebab-case `/configs` fields, `PATCH /configs` as 204/no-body). The previously uncertain mode payload is now confirmed: a running mihomo accepted `PATCH /configs` with `{"mode":"global"}`, `{"mode":"direct"}`, and `{"mode":"rule"}`, each returning 204 and reading back via `GET /configs`.

One more thing worth tracking, not a decision but a standing risk: **the target OS is a Beta (macOS 27 Beta).** `networksetup` behavior, Tun/`utun` interface creation, `launchd` semantics, and whatever mechanism item #1 resolves to are all APIs that can change between beta builds and the eventual public release. There's no action to take on this now beyond awareness — if the OS build on the Mac Mini changes materially before Phase 6 (`net` group) is reached, re-verify that phase's manual checklist against the new build rather than assuming prior verification still holds.

## 7. Rules for whoever (or whatever) works on this next

- **Update `README.md`'s status table every time you implement something.** Do not let it go stale — it's the fastest source of truth for the *next* handoff.
- **Update `CHANGELOG.md`** with any decision that changes behavior, conventions, or scope — the same way the SHA256 cancellation was recorded. Future assistants should never have to reverse-engineer *why* something is the way it is from code alone.
- **Do not modify the six non-negotiable conventions in §3** without updating every document that references them (`Full Specification`, `control_api_integration_spec`, this file) in the same change — these documents are cross-referential and a partial update creates exactly the kind of drift this handoff is meant to prevent.
- **Follow the layer order** in `mihomo_implementation_test_verification_plan.md`. It's dependency-ordered, not arbitrary — `net` in particular is deliberately last because it's the highest-risk, least-testable-in-CI layer and benefits from every other layer already being solid.
- **Keep `swift test` green after every implementation layer.** In restricted Codex sandboxes, the known-good invocation is `CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" SWIFTPM_CACHE_PATH="$PWD/.build/swiftpm-cache" swift test --disable-sandbox` from `mihomo-cli/`.
- **Final deliverable definition**: this project is "done" when every checkbox in every layer's verification-scheme checklist in `mihomo_implementation_test_verification_plan.md` is checked against a real build on real Apple Silicon hardware — not when the code merely compiles or unit tests pass. That document's closing line states this explicitly as the release gate.
