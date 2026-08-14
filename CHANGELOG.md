# CHANGELOG.md — Decision Log

Chronological record of every major decision made on this project, with rationale. This exists so no future AI assistant or human has to reverse-engineer *why* something is the way it is. Entries are grouped by the milestone they belong to, not by literal timestamp.

---

## 1. Initial design document

User supplied a design document (Chinese/English) for a pure-CLI mihomo kernel manager, macOS Apple Silicon only, no GUI. Core structure: kernel config management, subscription config management, network mode switching (System Proxy / Tun / Proxy Mode), rule mode switching (Rule / Global / Direct), plus a stability/security section covering atomic changes with rollback, process supervision, multi-layer pre-flight validation, fault-tolerant file I/O, and audit logging.

**Decision:** Treat this document as the foundation and review it before building anything, rather than starting implementation directly from a first draft.

## 2. Design review — 8 gaps identified

A structured review (informed by real mihomo/Clash ecosystem research, including prior-art macOS terminal clients) found:

1. macOS-specific integration mechanics (System Proxy interface targeting, Tun privilege model, process supervision mechanism) were asserted but never specified.
2. No defined precedence between CLI-driven rule-mode switches and a subscription's own embedded `mode:` field.
3. The `Refresh Interval: Always` label for local subscriptions conflated "re-read on activation" with "timer-based polling" — confusing.
4. The "fetch latest 10 releases" cap had no fallback for pinning an older/specific version not in that window.
5. No handling for a system proxy already owned by another application before this tool overwrites it.
6. No uninstall/teardown command, despite the tool potentially installing a `launchd` daemon and modifying system-level network state.
7. No audit log rotation/retention policy — logs were specified as "append-only" with no bound.
8. No stated behavior for two CLI invocations racing each other on mutating commands.

**Decision:** Fix all 8 rather than deferring any — these were all judged to be correctness/safety gaps, not nice-to-haves, given the tool mutates system-level network state.

## 3. v2 design document — gaps resolved

Each gap above was closed with a new or revised spec section:
- §2.3 macOS System Integration (privilege model, `launchd`-based supervision, explicit scope note that this is macOS-only, not abstracted).
- §2.4 Mode & Subscription Rule Precedence (CLI overlay always wins over the subscription's embedded default at runtime; **never edits the subscription file to apply this** — this constraint became one of the project's non-negotiable conventions).
- §1.2.1 relabeled `Always` → `Watch-on-use` (local) vs. numeric interval (remote).
- §1.1.3 added explicit-tag fetch (`kernel fetch <version>`) as a fallback beyond the top-10 window.
- §2.1 added conflicting-system-proxy detection before overwrite.
- §2.5 Teardown/Uninstall, with a `--purge-data` flag defaulting off (config/logs preserved unless explicitly requested).
- §4.1.6 Audit Log Retention — size-based rotation (10MB / 5 files default), never rotating the in-progress file mid-write.
- §3 added an advisory cross-invocation file lock, separate from the existing single-kernel-process lock.

**Decision:** These all became part of the "non-negotiable conventions" list in `AI.md` §3 because they were deliberate fixes to identified risks, not arbitrary style choices — reverting any of them silently would reintroduce a known gap.

## 4. Command surface + detailed per-group specs

A command surface sketch (§6, six groups: `kernel`, `sub`, `net`, `mode`, `daemon`, lifecycle/diagnostics) was written, then each group was expanded into a full command-by-command spec: exact flags, prompts, output formats, and a **shared exit-code table** (`0`–`8`, `130`) plus a **shared error-message format** (`error: <what> — <why> (<fix>)`).

**Decision:** Establish the exit-code table and error format as global conventions applied identically across every group, rather than letting each group invent its own — this was an explicit design goal stated at the start of the `net` spec and retroactively applied to `sub` and `kernel`.

**Decision, `net` group specifically:** System Proxy targets the single active network service automatically, but prompts when multiple are active rather than guessing or applying to all — chosen because silently proxying an unintended interface (e.g. a USB tether the user forgot was connected) is a worse failure mode than one extra prompt.

**Decision, `net tun` specifically:** Every code path that creates a Tun interface must have rollback-safe teardown reachable from every failure branch — orphaned `utun` devices surviving a crashed/rolled-back operation was identified as the single worst failure mode in the whole spec.

## 5. Consolidation into one Full Specification + Control-API Integration Spec

The five standalone per-group spec files were merged into one document (`mihomo_CLI_Manager_Full_Specification.md`) — design doc §1–5, command surface §6 as a quick reference, full per-group detail as Appendix A.

A separate `mihomo_control_api_integration_spec.md` was written to define exactly how the CLI talks to the running mihomo kernel's REST control API: endpoint-to-command mapping, connection/auth handling (loopback-only, manager-generated secret, never sourced from the user's subscription), and — critically — a precise three-part definition of **"liveness check"**, since every atomic-switch operation in every command group depends on this one concept and it had previously only been referenced, never defined.

**Decision:** The manager always owns and generates the control-API secret and port; the subscription's own `external-controller` block (if present) is ignored. Rationale: the manager needs guaranteed, unambiguous reachability to the kernel it just started, and trusting user-supplied connection details for this would undermine the atomic-switch/liveness-check machinery everywhere else.

**Decision, scope limit:** Per-node proxy selection (`PUT /proxies/{group}`) was wired into the `KernelClient` protocol since it's nearly free once the client exists, but explicitly **not exposed as a command** in this version — flagged as a natural v3 addition rather than scope-creeping the current command surface.

## 6. Project scaffold (Swift)

**Decision: Swift, via Swift Package Manager + `swift-argument-parser`.** Rationale: the tool is macOS-only by design (§3 of the design doc), needs to shell out to `networksetup`/`launchd`/Tun primitives natively, and has no cross-platform requirement that would favor Go or Rust. This was flagged to the user as an assumption at the time rather than a hard requirement, and not contested.

Every command/subcommand/flag from the Full Specification was scaffolded with `swift-argument-parser`, with all `run()` bodies throwing a structured "not implemented" `CLIError`. Shared support types were created: `MihomoExitCode`, `CLIError`, `AdvisoryLock` (initially stubbed), `KernelClient` protocol + `HTTPKernelClient` stub.

**Constraint noted at scaffold time and still true:** no Swift toolchain was available in the authoring sandbox. **Nothing in this project has ever been compiled or run.** This is the single most important caveat for whoever picks this up next.

## 7. SHA256 verification cancelled — official repository trust model adopted

**User's explicit instruction:** cancel the planned local SHA256 verification of downloaded kernel binaries; use the official upstream repository itself as the standard.

**What changed:** Every reference to "verify upstream SHA256 hash" / "recheck binary integrity" across the design doc, the kernel command spec, the daemon/diagnostics spec (in `doctor`'s check list), the consolidated Full Specification, and the control-API integration spec was rewritten. The new standard: a kernel binary is only ever fetched via HTTPS directly against the **official mihomo GitHub releases API**, for the exact requested tag; a response that doesn't resolve to a genuine official release asset (bad redirect, 404, malformed artifact) is refused and never registered. This is a **provenance check** (did this come from the right place), not a **checksum verification** (does this file's hash match a published value).

**What was deliberately kept:** `kernel use`/`start`/`restart` still perform a lightweight on-disk **presence/intactness check** (file exists, non-zero size) immediately before launch. This is not a reintroduction of SHA256 — it's a sanity check against the binary having been deleted or truncated between download and use, and was kept because launching a truncated binary silently is a worse failure mode than one cheap existence check. This distinction (provenance vs. presence vs. checksum) is called out explicitly in `AI.md` §3 to prevent future confusion or accidental reintroduction of the cancelled checksum step.

**Exit code `8`** was redefined from "SHA256 mismatch" to "source verification / binary presence failure" to match.

## 8. Support layer implemented for real

Rather than stay stubbed, the following were actually implemented (not just scaffolded) and unit-tested:
- `AdvisoryLock`: real `flock(2)` exclusive, non-blocking locking. Chosen over a PID-file convention specifically because a kernel-held `flock` cannot outlive a crashed process the way a stale PID file can — this was a deliberate design choice documented inline in the source, not just an implementation detail.
- `MetadataStore`: JSON-backed, `actor`-isolated (for in-process async safety; distinct from and complementary to `AdvisoryLock`'s cross-*process* guarantee), using temp-write + atomic-rename per the design doc's fault-tolerant-I/O requirement.
- `kernel list`, `sub list`, and `kernel rm`'s active-kernel guard were wired to real store data as the first concrete proof the store works end-to-end, rather than leaving every command stubbed.

**Decision:** wire at least a few real commands end-to-end rather than only building infrastructure, so there's a working (if narrow) vertical slice to build outward from.

## 9. Layer-by-layer implementation/test/verification plan

A single planning document was produced covering every remaining layer (`KernelClient` HTTP implementation → `kernel` group completion → `sub` group → `mode` group → `net` group → `daemon`/diagnostics group), each with an implementation scheme, a test plan (with an explicit CI-mockable vs. manual-only split), and a verification checklist.

**Decision, ordering:** `net` is deliberately last — it's the highest-risk, least-CI-testable layer (real `networksetup`/Tun/`launchd` interaction), and benefits from every other layer already being solid to validate against.

**Decision, flagged rather than guessed:** the exact macOS mechanism for Tun-mode privilege escalation (no direct `setcap` equivalent exists on macOS) is explicitly called out as something requiring a hardware prototype/spike before implementation, not something to assume from documentation. Same treatment for mihomo's actual `/configs`/`/proxies` response schemas — confirm against a real running instance rather than assume from general Clash API familiarity, since the Meta fork has extended the API over time.

**Decision, release gate:** the project is not "done" when code compiles or unit tests pass — it's done when every checkbox in every layer's manual verification checklist has been run against a real build on real Apple Silicon hardware. This was stated explicitly as the closing line of the verification plan and repeated in `AI.md` §7.

## 10. Handoff documentation

`AI.md` and this `CHANGELOG.md` were written specifically because the project is being handed off to other AI tooling for continued development, and the user required that no part of the requirement plan, functional scope, implementation status, or deliverable definition be lost in that handoff.

**Decision:** `AI.md` is the single entry point and source of truth for *current* state and *rules*; this file (`CHANGELOG.md`) is the source of truth for *history and rationale*. Anything that changes behavior, conventions, or scope going forward should be appended here, in the same style as entry §7 above (what changed, what was kept, why) — not just changed silently in code.

## 11. Requirement development plan + two conventions closed out

User asked for a project-management-level plan (distinct from the technical layer-by-layer implementation plan): what requirements are still undefined, and what gets delivered at each checkpoint. `docs/mihomo_requirement_development_plan.md` was written, surfacing 8 previously-untracked open questions beyond the two already-known hardware spikes (Tun privilege mechanism, mihomo API schema): code signing/notarization, distribution channel, the tool's own versioning/self-update policy, telemetry/privacy stance, output-language scope, non-interactive/scripting output behavior, minimum macOS version, and license. Each was tagged with an owner (AI-executable vs. human/hardware-required) so future work isn't blocked waiting on a decision an AI assistant could have made, nor silently decided on a question that actually needed a human/business call.

**Decision:** two of the AI-executable items were closed out immediately and added to `AI.md` §3 as conventions #11 and #12:

- **No telemetry, ever** (§3.11) — an explicit, stated guarantee rather than an implicit absence. The tool's only outbound network calls are to the official mihomo releases API (user-initiated kernel fetches) and whatever remote subscription URL the user themselves configured. Rationale: a proxy-management tool handles inherently privacy-sensitive data (subscription URLs, routing rules), so the absence of telemetry is worth stating as a hard constraint rather than leaving it as "nobody's built any telemetry yet, so there isn't any" — the latter framing invites someone to add analytics later without realizing that was never supposed to be on the table.
- **Non-interactive/non-TTY output policy** (§3.12) — every confirmation prompt across every command group must detect a non-interactive context and fail closed (clear error, requires `--yes`) rather than hang on `readLine()` waiting for input from a script or CI pipeline that will never provide it. Rationale: this was an actual latent bug risk — prompts were specified (`[y/N]`) without ever specifying what happens when there's no TTY to prompt, and a hung CLI command in an automated context is a worse failure mode than a slightly more verbose error.

The remaining 6 items (signing, distribution, tool versioning, output language, minimum macOS version, license) remain open, logged in the requirement development plan, awaiting a human/product decision — explicitly not something resolved or guessed at in this pass.

## 13. mihomo API reference notes researched, KernelClient corrected

User asked whether development could proceed, and whether further documentation was needed. Since the Swift toolchain is unavailable in this environment (nothing here can be compiled or run — that constraint hasn't changed), the highest-value non-hardware-dependent work available was de-risking requirement-closure item #2 (mihomo's actual API schema), which had been sitting on "guessed from general Clash API knowledge."

Fetched mihomo's official API documentation (`wiki.metacubex.one/en/api/`) directly and wrote `docs/mihomo_api_reference_notes.md`, an endpoint-by-endpoint reference mapped to which command in this project uses which endpoint. Applied the corrections it surfaced directly to `KernelClient.swift`:

- `Configs`/`ConfigsPatch`/`ProxyGroups`/`ConnectionsSnapshot` were placeholder-shaped guesses; now match real field names and structure (kebab-case JSON keys via explicit `CodingKeys`, `PATCH /configs` confirmed to return no body — meaning the config-readback sub-check in `livenessCheck` isn't just good practice, it's the *only* way to confirm a patch took effect, `ConnectionsSnapshot` decodes a real `connections` array rather than a nonexistent `count` field).
- Recommended switching `net status`/`doctor` from `GET /proxies` to `GET /group`, since `/group` returns only the policy groups this tool actually cares about, where `/proxies` also includes every individual leaf proxy this tool never displays independently.
- Corrected `selectProxy`'s request-body assumption (`{"name": "<node>"}` against `PUT /proxies/{group}` — group in the URL path, not the body).
- Explicitly noted mihomo's built-in `POST /upgrade` self-upgrade endpoint exists but is **deliberately not used** — this tool's multi-version side-by-side kernel management (the whole point of the `kernel` command group) is a different model than mihomo's in-place self-upgrade, and a future implementer simplifying `kernel check`/`kernel use` into a call to `/upgrade` would silently drop that feature. Flagged specifically to prevent that.

**What's still open:** the exact `PATCH /configs` payload for changing `mode` isn't shown in mihomo's own docs (their example patches `mixed-port`); the mechanism is confirmed, this one value isn't. Requirement-closure item #2 was downgraded from "needs a from-scratch investigation" to "needs a quick live confirmation of one field" — still logged as open, not fabricated.

**Decision:** this is documentation-and-code-correctness work, not a scope or convention change, so no new `AI.md` §3 convention was added — `AI.md`'s doc map (§2) and open-decisions section (§6) were updated instead to point at the new reference doc and reflect the reduced risk.

## 14. Scope confirmed: personal local use, single machine — 5 requirement-closure items canceled

**User's explicit instruction:** this tool is for personal local use only (no distribution to other users), and the exact target hardware/OS is a Mac Mini M4 running macOS 27 Beta — not a general "Apple Silicon" compatibility floor.

**What this closes:** requirement-closure register items #3 (code signing/notarization), #4 (distribution channel), #5 (tool's own versioning/self-update policy), and #10 (license) are all **canceled as not applicable** — none of them make sense for a tool that is built and run by the same person on the same machine, never distributed. Item #9 (minimum macOS version / support matrix) is **resolved**, not canceled: there is no matrix, just one exact target.

**What changed in code:** `Package.swift`'s platform floor changed from `.macOS(.v13)` (a generic "Ventura+" guess) to `.macOS("27.0")` (string-literal form, since macOS 27 likely predates a named enum case in whatever SwiftPM version ships with the Xcode/Swift toolchain actually available — flagged in a code comment to double check `swift-tools-version` and this string against `sw_vers -productVersion` once on the real machine).

**What changed in the phased plan:** Phase 8 (packaging & release readiness) is **canceled outright** — `swift build` on the target machine is the entire deployment mechanism, there's no artifact to package for anyone else. Phase 9's exit criteria was reframed from "tag a v1.0 release" to "every verification checklist item passes on the Mac Mini M4" — same rigor, different meaning of "done" (personal-use-ready, not distribution-ready).

**New risk surfaced, not resolved (logged, not actioned):** developing against a **Beta** OS means the APIs this project depends on most heavily for correctness — `networksetup` behavior, Tun/`utun` interface creation, `launchd` semantics, and whatever mechanism item #1 (Tun privilege escalation) resolves to — can all change between beta builds and the eventual public release of that macOS version. No action needed now; flagged in `AI.md` §6 as something to re-check against Phase 6's manual verification checklist if the OS build changes materially before that phase is reached.

**Knock-on effect on item #1 (Tun privilege mechanism):** previously noted as potentially needing a signed system extension (which would have required a paid Apple Developer Program enrollment) depending on how item #3 resolved. With #3 now canceled, there's no reason to build toward that heavier option — the simplest local mechanism (most likely a one-time `sudo`-gated step) is now the clear preferred direction, still to be confirmed by an actual prototype spike on the Mac Mini, but no longer a genuinely open fork in the road.

## 15. Duplicate AI.md/CHANGELOG.md copies removed

`AI.md` and `CHANGELOG.md` had been kept both at the package root and inside `mihomo-cli/`, on the rationale that `mihomo-cli/` might someday be separated into its own repo. User asked why, and — given the confirmed single-machine personal-use scope from entry §14 — agreed the scenario motivating the duplication (the Swift package being taken out of context by someone/something else) no longer applies. Removed `mihomo-cli/AI.md` and `mihomo-cli/CHANGELOG.md`; both files now live only at the package root.

**Decision:** `mihomo-cli/README.md` was updated to explicitly point back to the root copies (`../AI.md`, `../CHANGELOG.md`) rather than assuming they're present locally, so anyone opening `README.md` in isolation still knows where to look. Also corrected `README.md`'s spec file paths (they were missing the `../docs/` prefix from when this was a flat-file layout) and its stale "macOS 13+" build requirement note to match the actual `.macOS("27.0")` pin from entry §14.

Going forward: only one copy of each to keep in sync, at the package root.

## 16. README.md moved to package root

Following the same reasoning as entry §15: `README.md` was originally inside `mihomo-cli/` as project-local build instructions. User asked to move it to the package root alongside `AI.md`/`CHANGELOG.md`, consistent with those now being root-only too.

**What changed:** `README.md` now lives at the package root. Its content was updated to match: relative paths to `AI.md`/`CHANGELOG.md`/`docs/*` no longer use `../` (they're now siblings, not one level up); the build instructions now say `cd mihomo-cli` before `swift build`, since `Package.swift` is still inside that subfolder — only the documentation moved, not the Swift package itself; the "Layout" section was expanded to show the whole package-root tree (previously it only showed `Sources/mihomo-cli/`), and its references to the five superseded per-group spec files were corrected to point at `docs/mihomo_CLI_Manager_Full_Specification.md` Appendix A instead, since those standalone files were already superseded (entry from the original handoff work) but `README.md` hadn't been updated to reflect that at the time.

**Net effect:** the package root now has all three "entry" documents together — `AI.md`, `CHANGELOG.md`, `README.md` — and `mihomo-cli/` contains only the actual Swift package (`Package.swift`, `Sources/`, `Tests/`, `.gitignore`).

## 17. Tun-mode privilege mechanism — spike guide and validation script prepared

Requirement-closure item #1 (the last genuinely open item) moved from "needs a prototype spike" to "spike guide and script ready, needs execution on hardware."

**What was produced:** `docs/mihomo_tun_privilege_spike_guide.md` explains why root is unavoidable for `utun` interface creation on macOS (the `PF_SYSTEM`/`SYSPROTO_CONTROL` kernel control socket mechanism is root-gated at the kernel level — no `setcap` equivalent exists), compares two viable mechanisms given the confirmed local-only scope, and recommends one. `scripts/tun_privilege_spike.sh` is a runnable, non-destructive diagnostic: it compiles a minimal C probe that attempts real `utun` creation, confirms it fails without elevation (validates the premise), prints (but does not apply) the exact `visudo` command to add a scoped sudoers rule, then re-tests with `sudo` to confirm the mechanism actually works, cleaning up any test interface it creates.

**Recommendation given:** a `sudoers.d` NOPASSWD entry scoped to the exact mihomo kernel binary path (not a blanket NOPASSWD), over a root `launchd` daemon. Rationale: it matches this project's existing `net tun on/off` design (a per-invocation toggle) more cleanly than standing up an always-running root daemon would, and this project's existing `daemon` command group (§6.5 of the design doc) already means something different — user-level crash supervision of the manager-launched process — that would be conflated with privilege escalation if the two got merged.

**Deliberately not automated:** the script prints the `visudo` command/content rather than editing `/etc/sudoers.d/` itself. Programmatically modifying system security policy without the user directly reviewing the diff was judged not worth the convenience, even for personal single-user tooling — this is the one manual step in an otherwise-scripted validation flow, and that's intentional.

**Still open:** this is a recommendation and a way to test it, not a confirmed-working mechanism — that confirmation can only happen by actually running the script on the Mac Mini M4. `AI.md` §6 and the requirement development plan's register were updated to reflect "awaiting hardware execution," not "resolved."

## 18. KernelClient URLSession implementation completed

Layer 2 from `docs/mihomo_implementation_test_verification_plan.md` is now implemented for mocked/unit-test coverage. `HTTPKernelClient` no longer throws scaffold "not implemented" errors: it performs real `URLSession` requests against the manager-owned loopback control API, attaches `Authorization: Bearer <secret>`, uses a short `/version` reachability preflight before normal calls, decodes the corrected mihomo API shapes, maps HTTP/auth/decode/transport failures into `CLIError`, and implements the shared `livenessCheck(expectedVersion:expectedConfigPatch:)` composition used by future atomic switch workflows.

**Endpoint choices implemented:**
- `GET /version` for `version()` and the reachability/liveness preflight.
- `GET /configs` and `PATCH /configs` for config reads and runtime overlays; `PATCH` treats 204/no-body as success and relies on later readback for confirmation.
- `GET /group` for policy groups, following the earlier API-reference decision to avoid `/proxies` for status surfaces that only need switchable groups.
- `PUT /proxies/{group}` remains implemented only at the client layer for reserved future node-selection scope.
- `GET /connections` and `DELETE /connections` are implemented for later `net`/`doctor` use.

**Testing:** added `Tests/mihomo-cliTests/HTTPKernelClientTests.swift` with a mocked `URLProtocol` transport. Coverage includes bearer auth, `/configs` preflight, `PATCH /configs {"mode": ...}` body and 204 handling, `/group` decoding, reserved proxy selection, connection snapshot decoding, connection close, auth/404/decode/transport failure mapping, and healthy/version-mismatch/config-mismatch/unresponsive liveness outcomes. Full test command passed on 2026-08-13:

```
cd mihomo-cli
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" SWIFTPM_CACHE_PATH="$PWD/.build/swiftpm-cache" swift test --disable-sandbox --disable-automatic-resolution
```

After network access returned, the normal dependency-resolution path also passed:

```
cd mihomo-cli
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" SWIFTPM_CACHE_PATH="$PWD/.build/swiftpm-cache" swift test --disable-sandbox
```

Result: 27 XCTest tests, 0 failures. `--disable-sandbox` was required in the Codex sandbox because SwiftPM's own sandbox conflicted with Codex's filesystem sandbox. SwiftPM produced `Package.resolved` pinning `swift-argument-parser` to 1.8.2.

**Still pending:** live-instance verification against a real mihomo process. The only remaining Point 2 uncertainty is narrow: confirm that the installed mihomo accepts `PATCH /configs` with `{"mode":"rule"}`, `{"mode":"global"}`, and `{"mode":"direct"}` and that a follow-up `GET /configs` reads back the changed mode. This is now a smoke test during integration, not a blocking prototype spike.

## 19. `kernel fetch` implemented and smoke-tested against upstream

Layer 3 has started with the first kernel command slice: `mihomo kernel fetch` is now real for all three specified paths:

- No arguments fetches the latest stable release.
- `--all` fetches the latest 10 releases and skips versions already registered locally.
- An explicit tag fetches that exact release via `/releases/tags/<tag>`, bypassing the top-10 window.

**Implementation details:** added `GitHubKernelReleaseClient`, `KernelFetchService`, `ResumableDownloader`, and `KernelInstaller`. The fetch path reads official release metadata from `https://api.github.com/repos/MetaCubeX/mihomo`, selects the upstream-provided darwin-arm64 `browser_download_url`, verifies that URL points back to the official `github.com/MetaCubeX/mihomo/releases/download/<tag>/...` asset path, downloads with retry and Range-resume support, extracts the `.gz` archive with `/usr/bin/gunzip`, sets the installed binary to `0755`, and registers a `KernelRecord` in `MetadataStore`.

**Provenance policy preserved:** the code never constructs a release asset URL by hand. It only consumes the URL returned by the official release API and then checks that the URL still resolves to the official repository/tag path. No SHA256 verification was added.

**Testing:** added `KernelFetchTests` covering darwin-arm64 asset selection for stable and alpha releases, `fetch --all` skip-vs-download behavior, explicit missing-tag failure, missing-asset source verification, and Range-resume downloader behavior. Full suite passed on 2026-08-13:

```
cd mihomo-cli
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" SWIFTPM_CACHE_PATH="$PWD/.build/swiftpm-cache" swift test --disable-sandbox
```

Result: 33 XCTest tests, 0 failures.

**Live smoke test:** ran `swift run --disable-sandbox mihomo-cli kernel fetch` with network access restored. It downloaded and registered `v1.19.29`; `~/.mihomo-cli/kernels/v1.19.29/mihomo` is a Mach-O arm64 executable, and `mihomo -v` reported `Mihomo Meta v1.19.29 darwin arm64`. A second `kernel fetch v1.19.29` correctly printed `already present, skipped`.

**Still pending in Layer 3:** `kernel use`, `kernel check`, `kernel status`, a real interrupted-download resume test, and live control-API smoke testing against a running mihomo process.

## 20. Layer 3 `kernel use` risk review reconciled before implementation

Before starting `kernel use`, an external risk review (`/Users/john/Downloads/Layer3-Kernel-Use-Spec-Gaps-And-Risk-Review.md`) was read against the kernel, control-API, daemon/lifecycle, and implementation-plan docs. The review identified several real cross-spec interactions that were not explicit enough in the Layer 3 plan, especially because `kernel use` is intended to become the template for future atomic switch flows.

**Decision:** do not implement `kernel use` as a narrow command-local stop/start sequence. Build the shared lifecycle/process-control primitive first, and route `kernel use`, `start`, `stop`, `restart`, and later Tun launch paths through it. This avoids duplicating subtly different interpretations of "intentional stop," process stderr capture, port-release waiting, and rollback behavior.

**Plan changes applied:**
- The internal stop step in `kernel use` must mark the stop as intentional/expected using the same primitive as `mihomo stop`, so an installed launchd supervisor does not race the switch by auto-restarting the old kernel as if it crashed.
- `kernel use` must regenerate manager-owned control-API credentials and write the runtime config/overlay before spawning the target kernel, then authenticate `livenessCheck` with that fresh secret.
- After stopping the old process, the workflow must wait briefly for the old control/mixed ports to be released before starting the new process on the same ports; port release and "another app is squatting on the port" are distinct failure modes.
- Minimal subprocess stderr capture is required in Layer 3, even though full leveled/rotating logs remain Layer 7, because the spec's failed-switch guidance points users at `mihomo log --level error`.
- Rollback failure now has its own required message/contract. The tool must not print "Rolled back to ..." unless the rollback process actually starts and passes liveness.
- The already-active no-op check may happen before acquiring the advisory lock as an optimization, but it must be repeated inside the lock as the authoritative state check.

**Test plan changes applied:** add unit cases for rollback-of-rollback failure, post-lock no-op recheck, daemon-installed intentional stop semantics, and the stop→port-release wait before start. These are now in `docs/mihomo_implementation_test_verification_plan.md` and should be treated as part of the Layer 3 implementation contract, not optional polish.

## 12. Output language resolved — English-only

**User's explicit instruction:** English-only. No bilingual or localized output.

**What this closes:** requirement-closure register item #7. The original design document had Chinese-language framing, and it was left genuinely ambiguous whether that meant end-user output needed to support Chinese too, or was simply the document author's own working language. Confirmed: user-facing output is English only.

**What changed:** added as convention §3.13 in `AI.md`. No code changes required — every error message, prompt, and `--help` string written so far (all of it, across every stub and every implemented command) was already English-only by default, so this decision confirms the existing default rather than requiring any rework. Its main value is foreclosing the need for a string-table/locale-lookup architecture in Phase 4 (`sub` group) and beyond, where the next large batch of user-facing text was about to be written.

## 21. `kernel use` implemented, Point 2 live-confirmed, CLI error exit path fixed

Layer 3 advanced from `kernel fetch` only to a real `kernel use` implementation. The command now uses the shared switch shape required by the risk review: advisory locking with a post-lock no-op recheck, on-disk binary presence validation, regenerated manager-owned control-API credentials, generated runtime config under `~/.mihomo-cli/runtime/<version>/`, intentional stop marking for the previous running kernel, port-release wait, subprocess stdout/stderr capture, liveness retry/readback, active/running metadata persistence, and distinct rollback-failure reporting.

**Live verification:** with network access restored, fetched and installed `v1.19.29` and `v1.19.28`, then switched a real running mihomo process `v1.19.29` → `v1.19.28` → `v1.19.29`. `/version` reported the selected version after each switch, and the daemon expected-stop flag was reset to `false` after successful start observation.

**Requirement-closure item #2 closed:** the remaining `/configs` uncertainty is resolved. A running mihomo accepted:

```
PATCH /configs {"mode":"global"}
PATCH /configs {"mode":"direct"}
PATCH /configs {"mode":"rule"}
```

Each returned HTTP 204 and the changed mode read back via `GET /configs`. The requirement-development register, `AI.md`, API reference notes, and implementation checklist were updated to mark this resolved rather than still requiring a decision or hardware spike.

**CLI error path fixed:** live `kernel rm` active-removal regression exposed that thrown `CLIError`s were being formatted by ArgumentParser as `Error: error: ...` and exiting with its default code `1`, ignoring the project's `MihomoExitCode`. Added a custom executable entrypoint (`MihomoCLIEntrypoint`) that keeps ArgumentParser parsing/help behavior but maps `CLIError` directly to the spec's stderr format and custom exit code. Rechecked `.build/debug/mihomo-cli kernel rm v1.19.29 --yes`: exit `2`, no stdout, exact `error: cannot remove ...` stderr.

**Testing:** full suite passed on 2026-08-13:

```
cd mihomo-cli
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" SWIFTPM_CACHE_PATH="$PWD/.build/swiftpm-cache" swift test --disable-sandbox
```

Result: 40 XCTest tests, 0 failures.

**Still pending in Layer 3:** `kernel check`, `kernel status`, destructive/manual interrupted-download resume, and forced rollback verification under a deliberately stuck or failed new process.

## 22. Layer 3 complete — `kernel check`, `kernel status`, shared prompt helper, `kernel rm` disk deletion

Layer 3 (`kernel` group) is now fully implemented.

**What was built:**

- `Support/ConfirmationPrompt.swift` — shared `confirm(_:yes:)` helper implementing `AI.md §3.12`'s non-interactive/non-TTY output policy in one place. `isatty(STDIN_FILENO)` check: if stdin is not a TTY and `--yes` was not passed, throws `CLIError(exitCode: .validationFailure)` with a clear `--yes` suggestion rather than blocking on `readLine()`. Interactive path prints the question + `[y/N]` and returns `.confirmed` on `y`/`Y`, `.declined` otherwise.

- `Support/KernelCheckService.swift` — testable service encapsulating `kernel check` logic. Fetches latest stable release metadata via `KernelReleaseProviding` (no download), compares against the active kernel, calls the injected prompt, then on confirmation runs the combined atomic fetch+use sequence. Declining is always exit `0` (informational, not a failure).

- `Support/KernelStatusService.swift` — testable service encapsulating `kernel status` output. Queries `MetadataStore` for `RunningKernelState`/`DaemonState`, calls `KernelClient.version()` live via injected client to determine responsiveness. Provides `humanOutput(from:)` (table format matching the spec's exact layout) and `jsonOutput(from:)` (structured JSON for `--json`).

- `kernel rm` — replaced the confirmation stub with `ConfirmationPrompt.confirm(...)`. Also added binary directory deletion: after the store record is removed, the per-version kernel directory is deleted via `FileManager.removeItem(at:)`; a missing-or-already-deleted directory is a non-fatal warning, not an error, so the store record is always cleaned up.

**Design choices:**

- `KernelCheckService` injects fetch and use as `(String) async throws -> Void`/`KernelUseResult` closures rather than accepting the concrete `final class` services as instances — this mirrors the injection pattern used across the rest of the project (closure DI over subclassing) and avoids needing to open or subclass the `final` services.
- `KernelStatusService.humanOutput` deliberately does not call the control API itself — that call is encapsulated in `report()` and the result is a plain `StatusReport` value type. This makes both the human and JSON formatters pure functions, keeping the display logic separately testable.
- `kernel rm`'s directory removal targets the whole per-version directory (not just the binary) because `KernelInstaller` writes the binary into a dedicated subdirectory (`~/.mihomo-cli/kernels/<version>/mihomo`). Removing only the binary would leave an empty directory behind.

**Testing:** full suite passed on 2026-08-14:

```
cd mihomo-cli
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" SWIFTPM_CACHE_PATH="$PWD/.build/swiftpm-cache" swift test --disable-sandbox
```

Result: **53 XCTest tests, 0 failures** (up from 40). New tests:
- `KernelCheckServiceTests` (7 tests): already-at-latest, `--yes` fetches+switches, declined no-op, non-TTY throws validationFailure, no active kernel, no stable release error, fetch-fail prevents use.
- `KernelStatusTests` (6 tests): no running kernel (human+JSON), running+responsive (human+JSON), running+unresponsive, uptime formatting.

**Still pending (manual-only, Layer 3 verification checklist):**
- Interrupted-download resume: `kernel fetch` with mid-download kill, confirm re-run resumes from where it stopped.
- Forced rollback: `kernel use` with the new process SIGSTOPped mid-liveness-check — confirm timeout and rollback to previous version rather than hanging.

## 23. Layer 4 complete — `sub` group & `SubscriptionValidator`

Layer 4 (`sub` command group) is now fully implemented.

**What was built:**

- `Package.swift`: added `Yams` (v5.4.0) dependency for AST-based YAML parsing and line-numbered validation.
- `Support/SubscriptionValidator.swift`: full multi-layer validation engine:
  1. YAML syntax parsing with line numbers extracted from `YamlError` marks.
  2. Structure & parameter types validation (`mode`, `proxies`, `proxy-groups`, `rule-providers`, `rules`).
  3. Proxy type verification (`ss`, `vmess`, `vless`, `trojan`, `hysteria2`, `wireguard`, `tuic`, `snell`, etc.).
  4. Proxy group type and member target validation against declared proxies, groups, and built-in targets (`DIRECT`, `REJECT`, `GLOBAL`, `COMPATIBLE`, `PASS`).
  5. Rule semantic validation checking rule format, target policy resolution, and `RULE-SET` provider declarations.
  6. Rule provider validation checking `type`, `behavior`, `path`, and `url` presence.
  7. Formatted error messages matching the spec's exact style (`error: subscription rejected — X validation errors\n  line Y: ...`).
- `Support/SubscriptionService.swift`: service implementing all `sub` operations:
  - `addLocal`: file existence & format pre-flight validation, collision resolution (prompts or appends `-2`, `-3`), metadata persistence.
  - `addRemote`: Range-resumable download, pre-flight validation, managed storage in `~/.mihomo-cli/subscriptions/<name>.yaml`, collision handling.
  - `use`: atomic subscription switch with validation, runtime config overlay generation via `RuntimeConfigWriter`, kernel liveness verification, automatic rollback on failure, and mode precedence warning note comparison (§2.4).
  - `edit`: active subscription guard (`exit 2`), interactive `$EDITOR` spawn, post-edit re-validation setting `isFlaggedInvalid = true` without reverting user edits.
  - `remove`: active subscription guard (`exit 2`), confirmation prompt, managed file cleanup.
  - `refresh`: remote-only guard (`exit 2` for local subs), fault-tolerant download, atomic update, and active kernel runtime config reload.
  - `validate`: standalone dry-run validation with structured line-number reporting.
- `Support/RuntimeConfigWriter.swift`: updated to merge active subscription YAML content into runtime config while overlaying manager-owned `external-controller`, `secret`, `mixed-port`, and `mode`.
- `Commands/SubCommand.swift`: wired `add local`, `add remote`, `use`, `edit`, `rm`, `refresh`, and `validate` to `SubscriptionService`.

**Testing:**

- Added hand-written YAML test fixtures under `Tests/mihomo-cliTests/Fixtures/subscriptions/` (`valid_minimal.yaml`, `valid_full.yaml`, `invalid_syntax.yaml`, `invalid_proxy_type.yaml`, `invalid_group_reference.yaml`, `invalid_rule_provider.yaml`).
- `SubscriptionValidatorTests.swift` (7 unit tests): valid fixtures, syntax error line numbers, proxy type line numbers, group reference line numbers, rule provider line numbers, and formatted error string checks.
- `SubscriptionServiceTests.swift` (13 unit tests): `addLocal` success & rejection & collision resolution, `addRemote` success & interval bounds, `use` no-op & mode precedence note, `edit` active guard (exit 2), `remove` active guard & success, `refresh` local guard (exit 2) & remote success, and import safety test asserting user's source file bytes on disk are never mutated.
- Full test suite passed on 2026-08-14: **73 XCTest tests, 0 failures** (up from 53).

## 24. Layer 5 complete — `mode` group (`status`, `rule`, `global`, `direct`)

Layer 5 (`mode` command group) is now fully implemented.

**What was built:**

- `Support/ModeService.swift`: testable service implementing:
  - `status`: queries running kernel for effective mode via `KernelClient.getConfigs().mode`, cross-checks against the active subscription's embedded default mode (flagging `(matches)` or `(CLI override in effect)` per §2.4), and outputs human table or JSON.
  - `switchMode`: acquires advisory lock, verifies running kernel (fails closed with `exit 2` if not running), prompts for confirmation on `global` and `direct` modes (unless `--yes`), applies runtime patch via `KernelClient.patchConfigs`, and validates with `KernelClient.livenessCheck` readback.
- `Commands/ModeCommand.swift`: wired `Status`, `Rule`, `Global`, and `Direct` subcommands directly to `ModeService`.

**Design choices:**

- Never mutates the active subscription file on disk: mode changes are strictly runtime overlays through `PATCH /configs` (satisfying the fundamental design principle from §2.4).
- Confirmation safety gates: `global` (forces all traffic through proxy, risking LAN/captive-portal issues) and `direct` (bypasses proxy for all traffic) prompt the user when run interactively, and fail with `exit 2` when declined.
- Non-kernel guard: mutating commands fail immediately with `exit 2` if no kernel is running.

**Testing:**

- `ModeServiceTests.swift` (11 unit tests):
  - `testStatus_noRunningKernel`
  - `testStatus_matchingMode_humanOutput`
  - `testStatus_overriddenMode_humanOutput`
  - `testStatus_noActiveSubscription`
  - `testStatus_jsonOutput`
  - `testSwitchMode_noRunningKernel_throwsExit2`
  - `testSwitchMode_rule_success`
  - `testSwitchMode_global_yesFlag_skipsPromptAndPatches`
  - `testSwitchMode_global_declined_throwsExit2AndNeverPatches`
  - `testSwitchMode_direct_declined_throwsExit2AndNeverPatches`
  - `testSwitchMode_livenessFailure_surfacesError`
- Full test suite passed on 2026-08-14: **84 XCTest tests, 0 failures** (up from 73).

## 25. Layer 6 complete — `net` group (`status`, `system-proxy`, `tun`, `proxy-mode`, `off`)

Layer 6 (`net` command group) is now fully implemented.

**What was built:**

- `Support/Models.swift` & `Support/MetadataStore.swift`: added `ActiveNetworkMode` (`.none`, `.systemProxy`, `.tun`, `.proxyMode`) and `SystemProxySettings` with backward-compatible defensive decoding.
- `Support/NetworkSetup.swift`: testable wrapper around macOS `/usr/sbin/networksetup` managing service enumeration, active IP link detection, and HTTP/HTTPS web proxy configurations.
- `Support/PortInspector.swift`: testable wrapper around `/usr/sbin/lsof` (for TCP LISTEN port inspection and PID/command attribution) and `/sbin/ifconfig` (for active `utun*` interface collision detection).
- `Support/NetService.swift`: testable service implementing:
  - `status`: displays active mode, interface/port, elapsed since timestamp, and daemon supervision status in human-readable table or `--json`.
  - `systemProxyOn`: auto-targets single active network services, prompts or enforces `--interface` on ambiguous multiple interfaces, warns before overwriting pre-existing foreign proxies unless `--yes`, and sets macOS web proxy.
  - `systemProxyOff`: disables web proxy on the active service; warns if externally changed.
  - `tunOn`: detects utun interface collision (exit 7), checks/prompts for privileged entitlement setup (exit 6 if declined), and enables Tun mode.
  - `tunOff`: idempotent teardown of Tun mode.
  - `proxyModeOn`: pre-checks port availability via `lsof` with process attribution (exit 7 on collision), binds proxy mode.
  - `proxyModeOff`: idempotent teardown of proxy mode.
  - `off`: convenience command deactivating whichever mode is active.
  - **Mutual Exclusivity**: activating any network mode automatically tears down whichever mode was previously active.
- `Commands/NetCommand.swift`: wired all subcommands (`Status`, `SystemProxy.On`, `SystemProxy.Off`, `Tun.On`, `Tun.Off`, `ProxyMode.On`, `ProxyMode.Off`, `Off`) to `NetService`.

**Testing:**

- `NetworkSetupTests.swift` (4 unit tests): service list parsing, active IP detection, webproxy output parsing, lsof output parsing.
- `NetServiceTests.swift` (18 unit tests):
  - Status display in none, system-proxy, tun, proxy-mode, and json formats.
  - System proxy on: auto-selection, explicit interface, unknown interface (exit 7), foreign proxy collision prompt/decline (exit 2).
  - System proxy off: cleanup and idempotent off.
  - Tun on: utun conflict (exit 7), entitlement declined (exit 6), success.
  - Tun off: idempotent off.
  - Proxy mode on: port conflict with process attribution (exit 7), success.
  - Mutual exclusivity: activating Tun mode automatically disables pre-existing system proxy.
  - Convenience `net off` deactivation.
- Full test suite passed on 2026-08-14: **106 XCTest tests, 0 failures** (up from 84).

## 26. Layer 7 complete — `daemon`, Lifecycle, & Diagnostics

Layer 7 (`daemon` command group, manual lifecycle `start`/`stop`/`restart`, `log`, `audit`, `doctor`, and `uninstall`) is now fully implemented.

**What was built:**

- `Support/LaunchdAgent.swift`: testable service managing `~/Library/LaunchAgents/com.mihomo-cli.agent.plist` generation, `launchctl bootstrap`/`bootout`, and `MetadataStore` supervision state tracking (`daemon install`, `daemon remove`, `daemon status`).
- `Support/Logger.swift`: structured leveled logger (`info`, `warning`, `error`) supporting automatic size-based log rotation (5MB, 5 files) and immutable structured audit log engine (`audit.log`).
- `Support/LifecycleService.swift`: manual lifecycle management implementing:
  - `start`: integrity verification (exit 8 on missing/empty binary), already-running guard (exit 2), process spawn, control API liveness verification, and `markKernelStartObserved()`.
  - `stop`: not-running guard (exit 2), `markKernelStopExpected()` flag setting to prevent auto-restart races, SIGTERM/SIGKILL signal handling.
  - `restart`: atomic stop and start with configuration rollback on failure.
- `Support/DoctorService.swift`: dry-run diagnostic utility checking active kernel binary presence (exit 8 if missing), subscription validity, port availability, system proxy consistency, Tun entitlement, daemon health, and disk headroom.
- `Support/UninstallService.swift`: ordered, best-effort system teardown (stop kernel -> remove daemon -> revert proxy -> net off -> optional `--purge-data`).
- `Commands/DaemonCommand.swift`, `Commands/LifecycleCommands.swift`, `Commands/DiagnosticsCommands.swift`: wired all subcommands to their respective services.

**Testing:**

- `LaunchdAgentTests.swift` (4 unit tests): plist XML generation, install/remove state mutations, idempotent install/remove, status output.
- `LoggerTests.swift` (4 unit tests): leveled logging & level filtering, 5-file size rotation across boundaries, immutable audit log recording/filtering, relative since parsing.
- `LifecycleServiceTests.swift` (5 unit tests): already running exit 2, no active kernel exit 3, missing binary exit 8, successful start with liveness verification, stop with user-initiated flag marking.
- `DoctorServiceTests.swift` (4 unit tests): all checks passed table output, warnings summary reporting without failure, JSON output, missing binary exit 8.
- `UninstallServiceTests.swift` (2 unit tests): prompt decline exit 2, full teardown with `--purge-data`.
- Full test suite passed on 2026-08-14: **127 XCTest tests, 0 failures** (up from 106).






## 27. Bugfix — `net tun on` false-positive utun collision on real hardware

Manual QA on the Mac Mini surfaced `mihomo-cli net tun on` failing every time with `error: cannot start Tun mode — utun interface already claimed, likely by another VPN client`, even with `ps aux | grep mihomo` showing nothing running and no VPN client active.

**Root cause:** `PortInspector.isUtunInterfacePresent()` ran `ifconfig -l`, which only lists interface *names* — not state. macOS pre-allocates several `utun0`–`utun3`+ slots at boot for its own frameworks (Continuity, Personal Hotspot, etc.), so the name is present on essentially every Mac whether or not any VPN has ever connected. Treating name-presence as "claimed" made Tun mode permanently unusable, not just occasionally conflicting.

**Fix:** `PortInspector.isUtunInterfacePresent()` now runs `ifconfig -a` (flags + assigned addresses per interface, not just names) and only reports a collision when a `utun*` interface is both `UP` **and** carries a real address — an auto-assigned link-local IPv6 address (`fe80::...%utunN`) on an otherwise-idle `UP` slot does not count, since that's exactly the false-positive pattern observed on hardware; a real IPv4 address or a non-link-local IPv6 address does. The parsing logic is factored into a new static, directly-testable function, `PortInspector.hasActiveUtunTunnel(ifconfigOutput:)`.

**Also noted, not yet fixed (pre-existing, unrelated to this bug):** the same session's manual QA also showed `kernel use <already-active-version>` reporting "already the active kernel, nothing to do" while `ps aux` showed no such process running at all — i.e. the metadata store's "active" pointer had gone stale relative to the real process state (most likely from earlier testing sessions). `kernel use`'s no-op fast path only compares against the *stored* active-version pointer, never against whether a process is actually alive. This is worth a follow-up: either `kernel use`'s no-op check or `kernel status`/`doctor` should cross-check `MetadataStore.runningKernel()` + `ProcessController.isRunning(pid:)`, not just the active-kernel record, before declaring "nothing to do" (`kernel status` already does this cross-check for its own display — see `KernelStatusService.swift` — but `kernel use`'s no-op path does not; the two were implemented against different assumptions and should be reconciled).

**Testing:** `Tests/mihomo-cliTests/PortInspectorTests.swift` (new, 9 unit tests) — idle-Mac false-positive shape (UP slots with only link-local IPv6) reports no collision; live VPN with IPv4 tunnel address reports a collision; live VPN with a routable (non-link-local) IPv6 address reports a collision; `UP` with no address at all does not; a matching address on a `DOWN` interface does not; non-`utun` interfaces with real addresses never count; empty output; plus two smoke tests for the pre-existing `lsof` parser, which had no dedicated test file before. **Not yet re-verified on the real Mac Mini** — the original report came from hardware, but this fix has only been reasoned through and unit-tested against captured `ifconfig -a` output shapes, not run against `swift test` (no Swift toolchain in this sandbox environment); re-running `net tun on` on the actual machine remains the real confirmation.

## 28. Bugfix — `sub add local` (and every kernel launch) silently dropped `proxy-providers`/subscription content entirely

**Reported symptom:** importing a full mihomo config via `sub add local` that uses `proxy-providers` (and no top-level `proxies` list) was accepted without error, but the kernel started with an empty runtime config — `proxies: []`, `proxy-groups: []` — and `proxy-providers` was completely absent from it. `curl -x http://127.0.0.1:7890 ...` failed because there was nothing to proxy through.

**Root cause:** this had nothing to do with `proxy-providers` specifically, and nothing to do with `sub add local`'s import/validation step (which already accepts such a config correctly — `SubscriptionValidator` has no opinion on `proxy-providers` either way). The actual bug: **the two code paths that actually launch a kernel process — `KernelUseService.launch()` (used by `kernel use`) and `LifecycleService.performStart()` (used by `start`/`restart`/Tun-mode elevation relaunches) — never loaded the active subscription's content at all.** Both called `RuntimeConfigWriter.write(version:credentials:mixedPort:)`, the convenience overload that defaults `subscriptionYAML` to `nil`, which unconditionally falls back to the hardcoded empty passthrough template (`proxies: []`, `proxy-groups: []`, `rules: [MATCH,DIRECT]`) regardless of what subscription was active. This reproduces identically for a config with a plain `proxies:` list too — it isn't a proxy-providers-specific reduction, it's the active subscription being ignored outright at launch time.

The only two places that ever passed real subscription content into `RuntimeConfigWriter` were `SubscriptionService.use()` (`sub use`) and `SubscriptionService.refresh()` (`sub refresh`) — and only in the branch where a kernel was *already running*, i.e. hot-patching a live kernel's config over the control API's config-reload path. A subscription activated via `sub use` *before* any kernel was running, then started via `kernel use`/`start`, never got its content applied at all.

`RuntimeConfigWriter` itself was not the bug — its merge logic (load the full subscription YAML as a dictionary, overlay `mixed-port`/`external-controller`/`secret`/`mode`, re-dump the whole dictionary) already preserves arbitrary top-level keys like `proxy-providers` correctly; it just was never being given real content to merge on a fresh launch.

**Fix:**
- New `Support/SubscriptionContentLoader.swift` — factors the local-vs-remote subscription path resolution and file-loading logic (previously private, duplicated implicitly wherever it might be needed) out of `SubscriptionService` into a shared, reusable helper. `SubscriptionService.loadContent(for:)`/`destinationURL(for:)` are now thin wrappers around it (no behavior change there).
- `KernelUseService` and `LifecycleService` each gained a new injectable `activeSubscriptionContent: () async throws -> String?` dependency (default implementation reads `MetadataStore.shared.activeSubscription()` and loads its file via `SubscriptionContentLoader`, returning `nil` if no subscription is active). Both `launch()` (used by `kernel use`, including its own rollback-relaunch path) and `performStart()` (used by `start`, `restart`, and `setTunElevation`'s relaunch) now call this and pass the result as `subscriptionYAML` to `configWriter.write(...)`, instead of always passing `nil`.
- No changes to `RuntimeConfigWriter`'s merge logic itself, and no changes to `sub use`/`sub refresh`'s already-correct hot-patch behavior.

**Testing:**
- `Tests/mihomo-cliTests/RuntimeConfigWriterTests.swift` (new, 5 tests) — exercises the real `RuntimeConfigWriter` against a temp directory and parses the written `config.yaml` back with Yams to assert on it directly: a `proxy-providers`-only config (the exact bug report repro) preserves `proxy-providers`, its real `proxy-groups`, and its real `rules`, none of which get replaced by the empty fallback; a plain `proxies:`-list subscription still works as before; no active subscription still produces the empty passthrough config (and, notably, no fabricated `proxy-providers` key); `modeOverride` takes precedence over an embedded `mode:`, and the embedded `mode:` is used when no override is given.
- `KernelUseServiceTests.swift` (+2 tests) and `LifecycleServiceTests.swift` (+1 test) — regression guards asserting `activeSubscriptionContent()`'s return value actually reaches the config writer's `subscriptionYAML` parameter on both launch paths (and that "no active subscription" correctly passes `nil`, not silently erroring).
- `Package.swift`: the test target now also depends on the `Yams` product (previously only the executable target did), needed for `RuntimeConfigWriterTests` to parse written YAML back into a dictionary for direct assertions rather than string-matching.
- **Not yet run against `swift test` on real hardware** — same caveat as the utun fix above: no Swift toolchain in this sandbox. The reasoning and test expectations were traced by hand against the actual `RuntimeConfigWriter`/`KernelUseService`/`LifecycleService` source, but this needs a real `swift test` run (and ideally a real `sub add local` + `proxy-providers` repro end-to-end) to confirm.
