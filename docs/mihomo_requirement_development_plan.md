# mihomo-cli — Requirement Development Plan & Interim Deliverables

This document answers two questions: **what requirements are still undefined** (not just what code remains unwritten — see `docs/mihomo_implementation_test_verification_plan.md` for that), and **what should be delivered, in what order, with what exit criteria**, from here to a releasable v1.0.

It sits one level above the implementation plan: the implementation plan tells you how to build each layer; this document tells you what still needs to be *decided* before or during that build, and what a stakeholder should expect to receive at each checkpoint.

---

## 1. Requirement-closure register

Everything below is a real open question — not yet answered in any existing spec — that should be resolved before the phase that depends on it, not discovered mid-implementation. Each has an owner type: **AI-executable** (an assistant can resolve this by writing docs/code and reasoning from what already exists) vs. **human/hardware-required** (needs a real Mac, a business decision, or a legal/policy call that shouldn't be made unilaterally by an AI assistant).

| # | Open question | Why it matters | Owner | Blocks |
|---|---|---|---|---|
| 1 | ~~Tun-mode privilege escalation mechanism~~ **RESOLVED, hardware-confirmed (2026-08-13).** `scripts/tun_privilege_spike.sh` confirmed unprivileged `utun` creation fails with `Operation not permitted`, while elevated creation through `sudo` succeeds and tears down cleanly. Implementation should use `sudo`-elevated mihomo launch, with the guide's scoped `sudoers.d` NOPASSWD rule treated as an optional convenience and interactive `sudo` as the fallback. | `net tun on` can now be implemented against a confirmed mechanism | Closed | Phase 6 (`net` group) |
| 2 | ~~mihomo's actual `/configs` / `/proxies` response schema~~ **RESOLVED, live-confirmed (2026-08-13).** | `KernelClient`'s data types were corrected against mihomo's own official docs (`docs/mihomo_api_reference_notes.md`) and then smoke-tested against a running mihomo process. `PATCH /configs` with `{"mode":"global"}`, `{"mode":"direct"}`, and `{"mode":"rule"}` returned 204 and each value read back via `GET /configs`. | Closed | Phase 2 (`KernelClient`) |
| 3 | ~~Code signing & notarization~~ **CANCELED — not applicable.** Confirmed local personal use only, single machine (Mac Mini M4, macOS 27 Beta). Gatekeeper's quarantine/notarization checks apply to *downloaded* files, not binaries built locally with `swift build` and run by the same user who built them — so this was never actually going to block anything for this use case. Tun mode's privilege step (item #1) should still favor the simplest local mechanism (e.g. a one-time `sudo`-gated step) over anything that would require a paid Apple Developer Program enrollment (e.g. a proper Network Extension system extension), since that enrollment is exactly the kind of dependency this cancellation is meant to avoid. | N/A | Canceled |
| 4 | ~~Distribution channel~~ **CANCELED — not applicable.** No distribution; build-from-source-and-run-locally is the only path, and it already is one (`swift build`). | N/A | Canceled |
| 5 | ~~Tool's own release/versioning policy~~ **CANCELED — not applicable.** No releases are being cut; the source tree itself is the only "version" that exists, updated by rebuilding. A self-update command for the manager tool remains explicitly out of scope. | N/A | Canceled |
| 6 | ~~Telemetry / privacy stance~~ **RESOLVED** — see `AI.md` §3.11 | Nothing in any spec currently claims "no telemetry," but nothing implements any either — this should be an explicit, stated guarantee, not an implicit absence, especially given the tool handles proxy/subscription configs that are privacy-sensitive by nature | AI-executable — closed | — |
| 7 | ~~Output language~~ **RESOLVED — English-only.** No localization/bilingual support required. | Changes error-string architecture significantly if localization is required later — cheaper to decide now than retrofit | Human — closed | — |
| 8 | ~~Non-interactive / scripting-friendly output mode~~ **RESOLVED** — see `AI.md` §3.12 | Prompts (`[y/N]`) already assume an interactive TTY; undefined behavior when stdin isn't interactive and `--yes` wasn't passed could hang a script forever | AI-executable — closed | — |
| 9 | ~~Minimum macOS version / hardware support matrix~~ **RESOLVED — no matrix, single target.** Confirmed: Mac Mini M4, macOS 27 Beta, and nothing else. `Package.swift`'s platform floor has been updated from a generic `.macOS(.v13)` guess to `.macOS("27.0")` to match exactly. **New risk this surfaces, logged rather than resolved:** developing against a *Beta* OS means the exact APIs this tool depends on most heavily for risk (`networksetup` behavior, Tun/`utun` interface creation, `launchd` semantics, any entitlement/privilege mechanism for item #1) can change between beta builds and the eventual public release. There is no action to take on this now beyond awareness — re-verify Phase 6's manual checklist if the OS build changes materially before that phase is reached. | Resolved (with a new logged risk, not a new open question) | Closed |
| 10 | ~~License~~ **CANCELED — not applicable.** Personal local-use tooling, not published or distributed; no license file needed unless that changes. | N/A | Canceled |

**Recommendation:** requirement-closure items #1 and #2 are now closed by hardware/live verification. Items #3, #4, #5, #9, #10 are canceled/resolved outright given confirmed local-only, single-machine use, and #6, #7, #8 (telemetry, output language, non-interactive-output policy) are closed. No requirement-register item currently blocks continuing implementation; remaining work is code plus the verification checklists in `docs/mihomo_implementation_test_verification_plan.md`.

---

## 2. Phased plan with interim deliverables

Each phase lists: what it produces, what it depends on, and how to know it's actually done (exit criteria) — not just "code written." Phases 2–7 map directly onto the layers in `mihomo_implementation_test_verification_plan.md`; this section adds the phases that document doesn't cover (0, 1, 8, 9) and reframes 2–7 as deliverable checkpoints rather than engineering tasks.

### Phase 0 — Requirement closure (partial)

**Deliverable:** this document, plus resolutions for the AI-executable rows above (#6 telemetry statement, #8 non-interactive output policy), now written directly into `AI.md`'s conventions list as §3.11 and §3.12. **Done as of this revision.**

**Depends on:** nothing — can start immediately.

**Exit criteria:** rows #1, #2, #6, #7, and #8 have stated answers in `AI.md`/this register. **Met.** Rows #3, #4, #5, #9, and #10 are canceled or resolved as not applicable to single-machine local use.

### Phase 1 — Toolchain bring-up

**Deliverable:** a confirmed `swift build` success on real hardware, with every compile error found and fixed; a minimal CI workflow (`.github/workflows/swift.yml` or equivalent) running `swift build && swift test` on macOS runners.

**Depends on:** access to a real Apple Silicon Mac with Xcode/Swift 5.9+. Nothing else — this phase doesn't need any requirement-closure items resolved first, since it's purely "does the existing scaffold compile."

**Exit criteria:** `swift build` and `swift test` both succeed with zero errors on a clean checkout. This is explicitly called out in `AI.md` §7 as the very first task on real hardware — Phase 1 formalizes it as a gated deliverable rather than an assumption.

### Phase 2 — `KernelClient` real implementation

**Deliverable:** working `HTTPKernelClient` against a real mihomo instance; `livenessCheck` fully implemented and unit-tested per the implementation plan's Layer 2 test plan.

**Depends on:** requirement-closure item #2 (real API schema) — now resolved by official-doc correction plus live smoke testing.

**Exit criteria:** every checkbox in the implementation plan's Layer 2 verification scheme. Mocked/unit coverage and the mode-patch live smoke are complete; the remaining manual failure-timing check stays tracked in the implementation plan.

### Phase 3 — `kernel` group completion

**Deliverable:** `kernel fetch`, `kernel use`, `kernel check`, `kernel status` fully implemented (matching the kernel provenance policy — no SHA256, official-repo-only fetch). `ResumableDownloader` and `ProcessRunning`/`ProcessController` helpers exist as reusable components (flagged as cross-cutting in the implementation plan).

**Depends on:** Phase 2.

**Exit criteria:** implementation plan's Layer 3 verification scheme, fully checked.

### Phase 4 — `sub` group completion

**Deliverable:** `SubscriptionValidator` (YAML syntax/param/rule-semantic validation), `sub add`/`use`/`edit`/`rm`/`refresh`/`validate` fully implemented. `Yams` dependency added to `Package.swift`.

**Depends on:** Phase 3 (reuses `ResumableDownloader`). Requirement-closure item #7 (output language) is resolved as English-only — no localization architecture needed before writing this group's error strings.

**Exit criteria:** implementation plan's Layer 4 verification scheme, including the fixture-based validator tests.

### Phase 5 — `mode` group completion

**Deliverable:** all four `mode` commands implemented; the shared interactive-confirmation-prompt helper gets built here (currently blocking `kernel rm`'s full completion too — closing this gap retroactively unblocks that Phase 3 loose end).

**Depends on:** Phase 2 (`patchConfigs`/`getConfigs`).

**Exit criteria:** implementation plan's Layer 5 verification scheme. Additionally: confirm `kernel rm`'s interactive confirmation (stubbed since Phase "0"/the original Support-layer work) now works using the same helper, closing that older gap rather than leaving it stranded.

### Phase 6 — `net` group completion

**Deliverable:** `NetworkSetup` wrapper, `net system-proxy`/`tun`/`proxy-mode`/`status`/`off` fully implemented.

**Depends on:** requirement-closure item #1 (Tun privilege mechanism) — now resolved as `sudo`-elevated mihomo launch. The scoped NOPASSWD sudoers rule is an optional daily-use convenience, not a phase blocker; implementation must gracefully fall back to interactive `sudo`.

**Exit criteria:** implementation plan's Layer 6 verification scheme — the heaviest manual-QA phase in the whole project; the orphaned-`utun`-interface check in particular is a hard gate, not optional.

### Phase 7 — `daemon` + diagnostics completion

**Deliverable:** `LaunchdAgent`, `Logger` (leveled + rotating, retrofitted into every earlier phase's commands as a cleanup pass), `daemon install/remove/status`, `start`/`stop`/`restart`, `log`, `audit`, `doctor`, `uninstall`.

**Depends on:** Phases 2–6 (doctor composes checks from all of them).

**Exit criteria:** implementation plan's Layer 7 verification scheme, plus confirmation that the `Logger` retrofit pass actually touched every command from Phases 3–6 (not just new Phase 7 code) — call this out explicitly in a PR/commit checklist so it isn't silently skipped.

### Phase 8 — Packaging & release readiness — **CANCELED**

Not applicable for local personal use on a single machine. Signing/notarization (#3), distribution channel (#4), tool versioning policy (#5), and license (#10) are all canceled per the requirement-closure register — there's no "install artifact for someone else" to produce. `swift build` on the target Mac Mini M4 *is* the entire deployment mechanism.

### Phase 9 — Full verification & personal-use readiness gate

**Deliverable:** every checkbox across every layer's verification-scheme checklist in `mihomo_implementation_test_verification_plan.md`, checked against a build on the actual target machine (Mac Mini M4, macOS 27 Beta). This is the same gate already stated in `AI.md` §7, reframed: "release" no longer means a distributable artifact (Phase 8 is canceled) — it means the tool is fully trustworthy for the one person and one machine it's actually going to run on.

**Depends on:** Phases 1–7 (Phase 8 is skipped, not a dependency).

**Exit criteria:** every verification checklist item passes on the Mac Mini M4. No release tag, no distribution — this is simply "the tool is done and safe to use daily."

---

## 3. Consolidated interim deliverables list

For quick reference — what exists at the end of each phase, in delivery order:

| Phase | Deliverable |
|---|---|
| 0 | This plan; telemetry statement + non-interactive-output policy added to `AI.md` §3 |
| 1 | Compiling project + passing test suite + CI workflow file |
| 2 | Working `KernelClient`/`HTTPKernelClient` against a real mihomo instance |
| 3 | Complete `kernel` command group + `ResumableDownloader` + `ProcessController` |
| 4 | Complete `sub` command group + `SubscriptionValidator` + `Yams` dependency |
| 5 | Complete `mode` command group + shared confirmation-prompt helper (retroactively completes `kernel rm`) |
| 6 | Complete `net` command group + `NetworkSetup` wrapper (highest-risk phase; Tun mechanism is confirmed as sudo-elevated launch; signing is not a gate) |
| 7 | Complete `daemon`/diagnostics group + `Logger` (retrofitted across all prior phases) |
| 8 | *Canceled — not applicable for local personal use* |
| 9 | Personal-use readiness: every verification checklist item checked on the Mac Mini M4 |

---

## 4. Immediate recommendation

Phase 0's closures (#6, #7, #8 telemetry/language/non-interactive-output) are done; #1 and #2 are now hardware/live-confirmed; and #3/#4/#5/#9/#10 are canceled or resolved as single-machine-only per the local-use clarification. The next concrete task is continuing the implementation plan's Layer 3 work: finish `kernel check` and `kernel status`, while preserving the manual verification checklist for interrupted downloads and rollback behavior.
