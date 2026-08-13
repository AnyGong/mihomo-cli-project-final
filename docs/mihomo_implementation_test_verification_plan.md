# mihomo-cli — Implementation, Test & Verification Plan for Remaining Layers

Covers everything past the completed Support layer (`AdvisoryLock`, `MetadataStore`, `kernel list`/`sub list`/`kernel rm`): the `KernelClient` HTTP implementation, and the `kernel`, `sub`, `mode`, `net`, and `daemon`/diagnostics command groups.

Each layer below has three parts:
- **Implementation scheme** — what gets built, in what order, and the key design decisions to lock in before writing code.
- **Test plan** — what gets automated (unit + integration), and what a mock/fixture strategy looks like, since most of this talks to the OS or a real kernel process.
- **Verification scheme** — how to confirm the implementation actually satisfies the spec, both via automated acceptance checks and manual on-device QA (since some of this — Tun mode, `networksetup`, `launchd` — cannot be meaningfully faked in CI).

Layers are ordered by dependency, matching the README's implementation order. Each layer assumes every prior layer is done.

---

## Layer 2 — `KernelClient` (control-API integration)

Reference: `mihomo_control_api_integration_spec.md`

### Implementation scheme

1. **`URLSession`-backed `HTTPKernelClient`.** Replace every `notImplemented(...)` throw in `KernelAPI/KernelClient.swift` with a real request: **automated portion done 2026-08-13; live mode-patch smoke test complete.**
   - Shared `URLSession` configured with `timeoutIntervalForRequest = 5.0` (request timeout) and a custom connect-timeout wrapper — `URLSession` doesn't expose connect-timeout separately from request-timeout, so implement the 500ms connect check as a short-timeout preflight `GET /version` call, then a second call with the full 5s budget for the actual operation if the preflight succeeds. This matches the integration spec §2 distinction between "kernel isn't up" (fail fast) and "kernel is slow" (allow more time).
   - Every request carries `Authorization: Bearer <secret>` from `MetadataStore.controlAPICredentials()`.
   - JSON decode failures and non-2xx responses map to `CLIError` per the integration spec §6 table — this mapping belongs in the client, not scattered across command handlers, so every caller gets consistent error text for free.
2. **`livenessCheck` composition.** Implement the three sub-checks from integration spec §4 as three small private methods (`checkVersionResponds`, `checkVersionMatches`, `checkConfigMatches`), composed in `livenessCheck(expectedVersion:expectedConfigPatch:)`. Keep each sub-check independently testable.
3. **Response type completion.** Fill in the `TODO` fields in `Configs`, `ProxyGroups`, `ConnectionsSnapshot` against mihomo's actual `/configs` and `/proxies` response shapes — confirm field names against a running mihomo instance's `GET /configs` output rather than assuming the Clash API docs are exhaustive, since mihomo (the Meta fork) has added fields over time.
4. **Dependency injection point.** `KernelClient` stays a protocol; command handlers accept it as a constructor parameter (default `HTTPKernelClient`) rather than reaching for a singleton — this is what makes the test plan below possible.

### Test plan

- **Unit tests, mocked transport.** Inject a `URLProtocol` stub (standard Swift pattern: `class StubURLProtocol: URLProtocol` registered on the test session's configuration) to return canned responses without a real kernel running. Cover:
  - `version()` happy path and malformed-JSON path
  - `patchConfigs` happy path and a rejected-but-2xx response (mihomo logs a warning internally but still returns 200 — confirm the client doesn't treat this as success without a readback, per integration spec §4 sub-check 3)
  - 401 → auth-failure mapping
  - connect timeout simulated via a stub that never responds within the preflight window
- **`livenessCheck` unit tests**, each sub-check mocked independently:
  - all three pass → `.healthy`
  - version mismatch → `.versionMismatch`
  - config readback mismatch → `.configMismatch`
  - unresponsive → `.unresponsive`
- **Integration test (manual-run, not CI-gated)**: a test target variant that requires a real mihomo binary path via environment variable (`MIHOMO_TEST_BINARY`), starts it against a throwaway config, and runs the full `KernelClient` surface against it. Skipped automatically if the env var is unset, so `swift test` in CI never depends on having mihomo installed.

### Verification scheme

- [x] Every method in the `KernelClient` protocol has mocked-success coverage and shared HTTP/decode/transport failure coverage (`HTTPKernelClientTests`, 2026-08-13).
- [x] `livenessCheck`'s three sub-checks are independently unit-tested, not just tested in combination (`healthy`, `versionMismatch`, `configMismatch`, `unresponsive`, 2026-08-13).
- [x] Manual: run against a real, currently-installed mihomo binary on an Apple Silicon Mac; confirm `/version` returns the actual running version string (`v1.19.29`/`v1.19.28`, 2026-08-13).
- [x] Manual: confirm `PATCH /configs` accepts `{"mode":"global"}`, `{"mode":"direct"}`, and `{"mode":"rule"}` with HTTP 204 and that `GET /configs` reads each value back (2026-08-13).
- [ ] Manual: kill the mihomo process mid-test and confirm the client's next call fails fast (within ~500ms) rather than hanging for the full 5s request timeout — this is the "connect timeout, not request timeout" distinction from the spec, and it's easy to accidentally implement as one undifferentiated timeout.

---

## Layer 3 — Finish the `kernel` group

Reference: `mihomo_kernel_command_spec.md`. `list`, `rm`, `fetch`, and `use` are done; `check` and `status` remain.

### Implementation scheme

1. **`kernel fetch`** — three paths (no-args stable-only, `--all` top-10, explicit `<version>` tag): **implemented 2026-08-13; manual interrupted-download verification still pending.**
   - HTTP client against `https://api.github.com/repos/MetaCubeX/mihomo/releases` (list) and `/releases/tags/<tag>` (direct tag fetch). Both are within the sandbox's allowed domain list for future dev work, and are the correct official endpoints per the kernel provenance policy in the README.
   - Download the platform-matching asset (`darwin-arm64` or equivalent naming in mihomo's release assets) directly from the `browser_download_url` in the release JSON — never construct a download URL by hand, since that's exactly the kind of guessed-URL behavior the provenance policy is meant to avoid.
   - Resume-on-retry: use `URLSession`'s `Range` header support for resumable downloads; track partial-download state (temp file + byte offset) in a scratch location, not in `MetadataStore` (partial downloads aren't a durable record).
   - On success: `MetadataStore.upsertKernel(...)` with `isActive: false`.
2. **`kernel check`** — thin wrapper: fetch latest stable metadata (no download), compare version strings against `MetadataStore.activeKernel()`, then either print "already latest" or prompt and chain into `fetch` + `use` as described in the spec's combined-atomic-operation note.
3. **`kernel use`** — the first real atomic-switch implementation in the codebase, and the template for `sub use`, `net *`, and `mode *` later: **implemented and live-smoke-tested 2026-08-13; forced rollback manual test still pending.**
   - `AdvisoryLock.withLock { ... }` wraps the whole operation.
   - Build the shared lifecycle/process-control primitive first, not inside `kernel use` ad hoc. `kernel use`, `start`, `stop`, `restart`, and later Tun launch paths must all call the same `ProcessController`/lifecycle helper so "intentional stop" semantics are identical everywhere. In particular, the internal stop step used by `kernel use` must mark the stop as user-initiated/expected the same way `mihomo stop` does, so an installed launchd supervisor does not race the switch by auto-restarting the old binary as if it crashed.
   - Steps: optional pre-lock no-op check for a cheap fast path → acquire `AdvisoryLock` → re-read active kernel and repeat the no-op check inside the lock (authoritative TOCTOU-safe check) → backup current active-version pointer (already recoverable from `MetadataStore` — no separate backup file needed, since "backup" here just means "remember what to roll back to") → on-disk presence/intactness check on the target binary → regenerate control-API credentials and write the manager-owned runtime config/overlay that the new process will read at launch → intentional-stop current kernel through the shared lifecycle primitive → wait/verify the old process has released the control port and mixed-port before reuse (short timeout; distinguish "same process still releasing" from "another app is squatting on the port") → start target kernel as a subprocess (`Process` API) with stderr captured to an early scratch log path → `KernelClient.livenessCheck(expectedVersion: version, expectedConfigPatch: nil)` using the newly generated secret → on success, `MetadataStore.setActiveKernel(version:)`; on failure at any step, restart the previous version and report the staged failure per the spec's exact message format.
   - Rollback is not assumed to succeed. If restarting the previous kernel also fails its presence check, process start, port wait, or liveness check, report a distinct "kernel switch failed and automatic rollback also failed — no kernel is currently running" style error, with the rollback failure reason included. Do not print the normal "Rolled back to ..." success line unless rollback actually passed liveness.
   - Minimal stderr capture is part of Layer 3, even though the full leveled/rotating `Logger` remains Layer 7. A failed launch/liveness check must leave kernel stderr somewhere `mihomo log --level error` can later surface, or the spec's diagnostic suggestion points at empty state.
   - No-op path: if `version == activeKernel.version`, skip the workflow and print the "already active" message. The check may happen before the lock as an optimization, but it must also happen again after the lock is held.
4. **`kernel status`** — `KernelClient.version()` + process liveness + `MetadataStore.activeKernel()` for added/last-used timestamps + `MetadataStore.daemonState()` for the supervision line.

### Test plan

- **Unit tests (mocked GitHub API + mocked `KernelClient`)**:
  - `fetch --all` skips already-present versions (assert on which "download" calls were made vs. skipped, using a spy)
  - `fetch <version>` on a tag that doesn't exist → correct error message and exit code, zero registered kernels
- [x] `use` on the already-active version → no-op path taken, `KernelClient` never called.
- [x] `use` on the already-active version where the state changes between the pre-lock and post-lock checks → post-lock check wins; no switch starts.
- [ ] `use` where `livenessCheck` returns `.versionMismatch` → confirm rollback restarts the *previous* version's process (spy on the subprocess-start calls) and the store's active-kernel pointer is unchanged.
- [x] `use` where the forward switch fails and rollback also fails → emits the distinct rollback-failed message and does not claim rollback success.
- [x] `use` where the on-disk presence check fails (binary manually deleted between `fetch` and `use`) → correct exit code, no subprocess start attempted at all.
- [x] daemon-installed scenario: the internal stop step goes through the same user-initiated/expected-stop primitive as `mihomo stop`, so the launchd supervisor cannot treat the switch as a crash.
- [x] port-release race: after stopping the old process, the switch waits for the old control/mixed ports to be released before attempting the new spawn.
- **Process-management unit tests**: since `kernel use`/`start`/`restart` shell out to `Process`, wrap process start/stop behind a small `ProcessController` protocol (mirroring the `KernelClient` DI pattern) so these tests don't need a real mihomo binary. **Done for `kernel use`; broader `start`/`restart` coverage remains future Layer 7 work.**
- **Integration test (manual-run)**: extend the Layer 2 integration harness to run `kernel fetch` against the real GitHub API (network-gated, opt-in) and confirm the downloaded binary's reported `mihomo -v` output matches the requested tag.

### Verification scheme

- [x] `fetch` never constructs a download URL manually — code review checklist item, not just a test, since a hand-built URL could silently violate the provenance policy without any test catching it if the test itself also hand-builds the "expected" URL. Implemented by selecting `browser_download_url` from the official release JSON only.
- [x] `kernel use` unit coverage includes already-active fast path, post-lock no-op recheck, successful switch with shared fresh credentials, previous-process intentional stop plus port wait, missing-binary failure before start, and rollback-failure reporting (`KernelUseServiceTests`, 2026-08-13).
- [x] Manual: run `kernel use` against a real second kernel version and confirm the running control API reports the selected version. Verified live switches `v1.19.29` → `v1.19.28` → `v1.19.29` on 2026-08-13.
- [x] Manual: confirm successful live switch resets daemon expected-stop state (`lastStopWasUserInitiated == false`) after the new kernel start is observed (2026-08-13).
- [ ] Interrupting `fetch` (Ctrl-C or killing the process) mid-download, then re-running, resumes rather than restarting from zero — verify with a throttled/simulated slow connection or a large enough real release asset. Automated Range-resume behavior is unit-tested; destructive manual interruption is still pending.
- [ ] Manual: run `kernel use` against a real second kernel version, unplug network mid-liveness-check (simulate a stuck condition by sending SIGSTOP to the new process) — confirm the CLI eventually times out and rolls back to the previous version rather than hanging indefinitely.
- [x] Manual: confirm `kernel rm` (already implemented) still correctly blocks removal of whatever `kernel use` most recently activated — regression checked against active `v1.19.29`; executable returned exit `2`, no stdout, and exact stderr `error: cannot remove 'v1.19.29' ...` (2026-08-13).

---

## Layer 4 — `sub` group

Reference: `mihomo_sub_command_spec.md`. Only `list` is done.

### Implementation scheme

1. **YAML validation core** (`Support/SubscriptionValidator.swift`, new file) — this is the largest new component:
   - Parse with a Swift YAML library (add `swift-yaml` or `Yams` as a package dependency — not yet in `Package.swift`, needs to be added in this layer).
   - Layered checks per design doc §4.1.3: (a) YAML syntax, (b) parameter validity (known keys, correct types — e.g. `port` is an int, `proxies` is a list), (c) rule semantic validation (every rule referencing a proxy-group name that must exist; every `rule-provider` referencing a resolvable path/url, matching the review-flagged gap that made it into §1.2.2), (d) port/path collision check against other subscriptions' declared ports if applicable.
   - Return a structured `[ValidationIssue]` (line number + message), not just a boolean, since every command spec's error output format depends on itemized line-numbered errors.
2. **`sub add local` / `sub add remote`** — name-collision handling via `MetadataStore.uniqueSubscriptionName`, validate before persisting, never write the file into the managed directory until validation passes (design doc §1.2.2: "invalid configurations are rejected immediately" — meaning nothing durable happens on failure).
3. **`sub use`** — second implementation of the atomic-switch pattern from Layer 3; can mostly copy `kernel use`'s shape (backup pointer → validate target → `KernelClient.patchConfigs` if the subscription needs to change kernel-visible config → liveness check via config readback → persist). Add the mode-precedence note (§2.4) as a post-success print, comparing the subscription's embedded `mode:` field against `KernelClient.getConfigs().mode`.
4. **`sub edit`** — shell to `$EDITOR` via `Process`, block if active (check `MetadataStore.activeSubscription()`), re-validate on return and set `isFlaggedInvalid` via `MetadataStore.upsertSubscription` rather than reverting.
5. **`sub refresh`** — remote-only guard, then the same resumable-download logic built for `kernel fetch` in Layer 3 (extract that into a shared `ResumableDownloader` helper now that a second caller exists — don't duplicate it).
6. **`sub rm` / `sub validate`** — thin, mostly already-established patterns from `kernel rm`.

### Test plan

- **Validator unit tests** — this needs the richest fixture set in the whole project: a `Tests/mihomo-cliTests/Fixtures/subscriptions/` directory with hand-written YAML files covering: valid minimal config, valid full-featured config, syntax-broken YAML, a rule referencing a non-existent proxy-group, a `rule-provider` with a dangling path, a duplicate port collision against a second fixture. One test per fixture, asserting the exact `ValidationIssue` list (not just pass/fail) — line-number correctness matters because it's user-facing.
- **`sub use` atomic-switch tests** — mirror the `kernel use` test shape from Layer 3: no-op on already-active, rollback on liveness failure, mode-precedence note only prints when there's an actual mismatch (test both branches).
- **`sub edit` tests** — mock `$EDITOR` as a script that mutates the fixture file predictably (e.g. `cp broken.yaml $1`), confirm `isFlaggedInvalid` gets set and the file itself is untouched by any rollback logic.
- **Import-safety test** — explicit regression test asserting that after `sub use`, the original subscription file's bytes on disk are byte-for-byte unchanged (guards the "never mutates the source file" guarantee added as a v2 fix in the design doc §1.2.2, which was a direct response to a review-flagged risk).

### Verification scheme

- [ ] Every validation error message shown by `sub add`/`sub validate` includes a correct line number — spot-check at least 5 fixture files by hand against the actual file content.
- [ ] Confirm `sub use` on a subscription with an embedded `mode: global` while the CLI's last `mode` command was `rule` prints the mismatch note exactly as specified — this is the kind of formatting detail unit tests alone won't catch if the print statement drifts from the spec's example over time, so a manual read-through of the literal terminal output is worth the five minutes.
- [ ] Manual: point `sub add remote` at a real subscription URL (or a local HTTP server serving a fixture) and confirm the refresh-interval default (60) and range validation (1–1440) behave as specified at both boundaries.
- [ ] Manual, destructive-test: `sub edit` the active subscription — confirm it's blocked with the exact message in the spec, not a generic permission error.

---

## Layer 5 — `mode` group

Reference: `mihomo_mode_command_spec.md`. Nothing implemented yet, but this is the smallest group.

### Implementation scheme

1. All four commands are thin now that `KernelClient.patchConfigs`/`getConfigs` exist from Layer 2: `mode status` reads and compares; `mode rule`/`global`/`direct` call `patchConfigs(ConfigsPatch(mode: "..."))` then `livenessCheck(expectedVersion: nil, expectedConfigPatch: ...)`.
2. No-kernel-running guard (`CLIError.noKernelRunning`) is a single shared precondition check at the top of every mutating command — factor into a small `requireRunningKernel()` helper in `Support/` since three commands need it identically.
3. `global`/`direct` confirmation prompts reuse whatever shared interactive-prompt helper gets built to unblock `kernel rm`'s currently-stubbed confirmation (flagged as a gap in the current README) — this is a good forcing function to finally build that helper, since by Layer 5 three separate commands are blocked on it.

### Test plan

- Unit tests per command: no-kernel-running guard fires correctly; successful patch + matching readback → success message; patch succeeds but readback doesn't match (simulated via mocked `KernelClient`) → correctly surfaces as a liveness failure, not a silent success.
- Confirmation-prompt tests: `--yes` skips the prompt; declining (mocked stdin "n") aborts with exit `2` and *no* `patchConfigs` call made — assert the mock client's patch method was never invoked, not just that the exit code is right, since a bug that prompts-then-applies-anyway would still show exit `2` if the print statements are wrong but the call still fires.

### Verification scheme

- [ ] `mode status`'s embedded-default-vs-effective-mode comparison correctly reads the *currently active* subscription's YAML (not a cached copy) — verify by switching subscriptions with different embedded modes and re-running `mode status` without any `mode` command in between.
- [ ] Manual: confirm `mode global`'s LAN-access warning text renders exactly as specified before any real behavior change ships — this is a safety-relevant prompt, worth a literal side-by-side read against the spec.

---

## Layer 6 — `net` group

Reference: `mihomo_net_command_spec.md`. Highest-risk layer — real system mutation (`networksetup`, Tun interfaces, sudo-elevated kernel launch). Nothing implemented yet.

### Implementation scheme

1. **`networksetup` wrapper** (`Support/NetworkSetup.swift`, new file) — thin `Process`-based wrapper around `networksetup -listallnetworkservices`, `-getwebproxy <service>`, `-setwebproxy <service> <host> <port>`, `-setwebproxystate <service> off`, parsing the (simple, line-based) stdout format. Keep all `networksetup` invocations behind this one file so nothing else in the codebase shells out to it directly — makes the whole surface mockable for tests.
2. **`net system-proxy on/off`** — enumerate via the wrapper, single-vs-multiple-service branching exactly as specced, conflict detection by comparing current `-getwebproxy` output against the last value this tool wrote (stored in `MetadataStore` — add a `lastAppliedSystemProxy` field to `MetadataDocument` for this, since "did *we* set this" is state the store needs to track, not something derivable from `networksetup` output alone).
3. **`net tun on/off`** — the highest-risk implementation in the tool:
   - Privilege check: use the hardware-confirmed mechanism from requirement-closure item #1 — launch the mihomo kernel through `sudo` when Tun mode is active. Detect whether the optional scoped NOPASSWD sudoers rule is present, and fall back to interactive `sudo` if not.
   - Conflict detection: enumerate existing `utun*` interfaces via `ifconfig` (wrapped similarly to `NetworkSetup`) before attempting to create one.
   - Rollback-safe teardown: any code path that creates the interface must have a matching teardown call reachable from every error branch, not just the "happy path off" — this is the one place in the whole codebase where a `defer`-based cleanup pattern is more important than the general `AdvisoryLock.withLock` pattern, since a partially-created interface surviving process exit is exactly the "orphaned utun device" failure mode called out in the spec.
4. **`net proxy-mode on/off`** — simplest of the three; port-conflict detection via `lsof -i :<port>` (wrapped, parse PID + process name from output), no privileged operations at all.
5. **`net status` / `net off`** — read from `MetadataStore` for "which mode is active" rather than re-deriving it by probing the OS every time, though `doctor` (Layer 7) will cross-check the two and flag drift.

### Test plan

- **`NetworkSetup` wrapper unit tests** — since this wraps `Process`, inject a `ProcessRunning` protocol (same DI pattern as `KernelClient`/`ProcessController`) with a fake that returns canned `networksetup`-style output strings; test the parsing logic against real captured output samples (capture actual `networksetup -listallnetworkservices` output on a real Mac once, check it into fixtures).
- **`net system-proxy on` branching tests**: single active service → auto-targets, no prompt; multiple active services + no `--interface` + non-interactive → exit `1`; multiple + `--interface` given → targets the specified one without prompting; existing foreign proxy detected → prompts, `--yes` skips prompt.
- **Tun mode tests are necessarily mostly manual** — the entitlement/privilege mechanism and real interface creation can't be meaningfully unit-tested without a real macOS kernel underneath. Keep the *conflict-detection* and *state-tracking* logic (does the code correctly refuse when a utun already exists, does teardown get called on every error path) unit-testable behind the same DI pattern; leave "does Tun mode actually route traffic" to manual verification.
- **Port-conflict unit tests** for `proxy-mode`: mocked `lsof` output with and without a match, confirm process-name attribution renders correctly when available and degrades gracefully ("in use by unknown process") when `lsof` itself fails due to permissions.

### Verification scheme

- [ ] Manual, on real hardware, with a second network service enabled (e.g. USB Ethernet alongside Wi-Fi): confirm `net system-proxy on` prompts correctly and applies to the chosen service only — check via System Settings, not just the tool's own status output, to catch cases where the tool believes it succeeded but macOS disagrees.
- [ ] Manual: start another VPN client (or a leftover `utun` from a previous crashed run) before `net tun on` — confirm the conflict is detected and reported per spec, not a generic OS-level error bubbling up.
- [ ] Manual, the most important test in this layer: force a liveness-check failure during `net tun on` (e.g. by making the mihomo control API port unreachable right after interface creation) and confirm `ifconfig` shows **no leftover `utun` device** afterward. This is the orphaned-interface regression the design doc's rollback guarantee exists to prevent, and it's the one failure mode that's easy to get right in the happy path and silently wrong in the failure path.
- [ ] Manual: run `net off` with each of the three modes active in turn, confirm each correctly identifies and reverts the active one.

---

## Layer 7 — `daemon` + diagnostics

Reference: `mihomo_daemon_lifecycle_diagnostics_spec.md`. Nothing implemented yet; `doctor` in particular is designed to compose checks built in Layers 2–6, so this layer is mostly integration rather than new primitives.

### Implementation scheme

1. **`daemon install/remove/status`** — generate and write a `launchd` plist (`Support/LaunchdAgent.swift`, new file) to `~/Library/LaunchAgents/com.mihomo-cli.agent.plist`, shell to `launchctl bootstrap`/`bootout` (wrapped, same DI pattern). Store `installed`/`restartCount`/`lastRestartAt` in `MetadataStore.daemon` (already modeled in `DaemonState` from Layer 1 — this layer is the first consumer of fields that already exist in `Models.swift`).
2. **`start`/`stop`/`restart`** — `stop` sets `MetadataStore.updateDaemonState { $0.lastStopWasUserInitiated = true }` (also already modeled) before signaling the process, which is the mechanism the design doc's auto-restart-except-intentional behavior depends on; the `launchd` agent's actual crash-vs-intentional detection logic reads this flag.
3. **`log`/`audit`** — implement the leveled/append-only logger itself first (this hasn't been built in any prior layer — every command so far has just used `print`). Introduce a small `Logger` type in `Support/` that every command handler should have been calling all along; retrofitting calls into Layers 3–6's commands is part of this layer's scope, not skippable.
4. **`doctor`** — literally calls into: `KernelClient.livenessCheck` (Layer 2), `SubscriptionValidator` (Layer 4) against the active subscription, `lsof`-based port check (Layer 6's helper), `NetworkSetup` consistency check (Layer 6), Tun entitlement check (Layer 6), `daemon status` (this layer), and disk-space/log-rotation headroom (new, small). This is the integration-test-by-construction command mentioned in the earlier plan — implementing it last, after every dependency is real, is deliberate.
5. **`uninstall`** — sequenced calls into `daemon remove`, `net off` (all three sub-modes), each wrapped so a failure in one step doesn't abort the sequence, per the spec's explicit deviation from the atomic-rollback pattern used everywhere else.

### Test plan

- **`LaunchdAgent` plist-generation unit tests** — snapshot-test the generated XML against a known-good fixture; don't unit-test `launchctl` invocation itself (mock it), since actually bootstrapping an agent is inherently a manual/integration concern.
- **`Logger` unit tests** — level filtering, rotation trigger at the configured size threshold, and the "never delete the in-progress file mid-write" guarantee from §4.1.6 (write while a rotation is triggered concurrently, assert no data loss in the active file).
- **`stop` → daemon-flag interaction test**: call `stop`, assert `MetadataStore.daemonState().lastStopWasUserInitiated == true` immediately after, before any daemon process would have observed it — this is a state-correctness test, not a behavioral one, since the actual crash-vs-intentional logic lives in the `launchd` agent's shell wrapper, which is not itself Swift code under test here.
- **`doctor` composition test**: mock every one of its six-plus dependencies independently, assert `doctor` calls all of them and aggregates results correctly — this is the layer's highest-value test, since a regression here means the diagnostic tool users reach for when something's broken is itself untrustworthy.
- **`uninstall` partial-failure test**: mock one step (e.g. Tun teardown) to fail, assert the remaining steps still ran and the command still exits `0` with the failing step reported as a warning, per the spec's explicit "best effort" deviation.

### Verification scheme

- [ ] Manual: `daemon install`, then force-kill the mihomo process directly (not via `mihomo stop`) — confirm the `launchd` agent actually restarts it and `daemon status` reports the incremented restart count with a reason.
- [ ] Manual: `mihomo stop` while the daemon is installed — confirm it does **not** get auto-restarted (this is the single most important manual check in this layer, since it's the one place a subtle bug silently defeats the point of `stop` existing as a distinct command from "kill and hope the daemon doesn't notice").
- [ ] Manual: run `doctor` in a deliberately broken state (e.g. system proxy manually changed outside the tool) and confirm it reports the mismatch as a warning without exiting non-zero, matching the "warnings never fail the command" rule.
- [ ] Manual: `uninstall --purge-data` on a fully-configured install, then confirm via Finder/`ls ~/.mihomo-cli` and System Settings that every trace is actually gone — the automated partial-failure test above checks the *reporting* logic, not that the underlying system calls actually work end-to-end.

---

## Cross-cutting notes

- **Shared helpers this plan introduces that don't belong to any single layer**: `ProcessRunning`/`ProcessController` (process DI, needed from Layer 3 onward), a shared interactive-confirmation-prompt helper (needed from Layer 3's `kernel rm` onward, currently stubbed), `ResumableDownloader` (built in Layer 3 for `kernel fetch`, reused in Layer 4 for `sub refresh`), and `Logger` (introduced in Layer 7 but should retroactively be wired into every earlier layer's commands once it exists — track this as a cleanup pass after Layer 7 rather than blocking Layer 7 on rewriting Layers 3–6).
- **CI vs. manual split**: every layer's automated test suite should be runnable with `swift test` on a CI runner with no network access and no elevated privileges — hence the heavy use of DI/mocking for `Process`, `URLSession`, and `networksetup`. The manual verification checklists are what actually exercise real Apple Silicon behavior (Tun mode, `launchd`, System Settings state) and can't be meaningfully replaced by CI; they should be run by hand before any tagged release, not treated as optional.
- **Suggested release gate**: don't consider the tool release-ready until every unchecked box across all seven verification-scheme checklists above is checked at least once against a real build on real hardware.
