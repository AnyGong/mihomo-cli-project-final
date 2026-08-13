# mihomo Control-API Integration Layer — Design Spec

The one component every command group in the Full Specification depends on: a client library that talks to the running mihomo kernel's built-in RESTful API (`external-controller`). This document specifies the client's responsibilities, endpoint usage, connection/auth handling, and error mapping back to the CLI's exit codes.

This is an internal library (`internal/kernelapi` or equivalent), not a user-facing command group — no `mihomo api ...` subcommand is planned. It's consumed by `net`, `mode`, `kernel status`, `kernel use` (liveness check), `daemon status`, and `doctor`.

> **See also:** `docs/mihomo_api_reference_notes.md` for the endpoint-by-endpoint field reference sourced from mihomo's own official documentation, including a few corrections already applied to `KernelClient.swift` (kebab-case field names, `PATCH /configs` returning no body, `/group` vs. `/proxies` for this tool's actual use case). This document (§3 below) stays the authoritative source for *which* endpoint each command uses; the reference notes are the authoritative source for *exact response shape*.

---

## 1. What the mihomo API actually is

mihomo (the maintained Clash Meta fork) exposes a REST API — the same "Clash API" that dashboards like metacubexd and yacd talk to — controlled by the `external-controller` config key. <cite index="7-1">This binds by default to a loopback address such as 127.0.0.1:9090, alongside optional CORS settings, a bundled UI file server, and a secret for authentication</cite>. Anyone who can reach that port can change routing behavior, so <cite index="7-1">a secret is strongly recommended any time the controller isn't strictly loopback-only</cite>.

This tool always binds the controller to loopback (`127.0.0.1`) and generates a random secret at first-run setup, since there's no legitimate reason for this CLI's use case to expose the control API beyond the local machine.

## 2. Connection & auth handling

- **Discovery:** The manager owns kernel configuration, so it writes `external-controller` and `secret` itself into the generated runtime config (the overlay from §2.4 of the design doc) rather than reading them from the user's subscription — the subscription's own `external-controller` block, if present, is ignored/overridden to guarantee the manager always knows how to reach the kernel it started.
- **Port selection:** Defaults to `127.0.0.1:9090`. If occupied (checked as part of the pre-flight in §4.1.3), the manager picks the next free loopback port automatically and records it, rather than failing — this mirrors the approach some multi-instance-aware clients take of never assuming a fixed port.
- **Secret storage:** Generated once per kernel instance (regenerated on every `kernel use`/`start`), stored in the manager's local metadata store (not the subscription file), and passed as an `Authorization: Bearer <secret>` header on every request.
- **Reachability check:** Every client call has a short connect timeout (500ms) distinct from the request timeout (5s default) — the control API is a local loopback call, so a slow connect almost always means the kernel isn't up yet rather than network latency, and should fail fast into the "kernel not running" error path rather than hanging.

## 3. Endpoint usage by command group

| Endpoint | Method | Used by | Purpose |
|---|---|---|---|
| `/version` | GET | `kernel status`, `doctor`, liveness checks in `kernel use`/`start`/`restart` | Confirms the control API is up and reports the running kernel's version string, which is cross-checked against the version the manager believes it launched |
| `/configs` | GET | `mode status`, `net status`, `doctor` | Reads current mode, ports, and other live runtime config |
| `/configs` | PATCH | `mode rule\|global\|direct` | Applies the mode overlay (§2.4) at runtime without touching the subscription file — this is the mechanism behind the "no manual edits to config files" guarantee. **Returns HTTP 204 with no body on success** — confirming the change actually applied requires a follow-up `GET /configs` (this is exactly what `livenessCheck`'s config-readback sub-check does; it isn't optional, it's the only confirmation mechanism that exists) |
| `/group` | GET | `net status`, `doctor` | **Corrected from `/proxies` (see `docs/mihomo_api_reference_notes.md`)** — `/group` returns only policy groups (the switchable units this tool cares about), where `/proxies` also includes every individual leaf proxy this tool never displays independently. Lists proxy groups and the currently selected node (`now`) per group |
| `/proxies/{group}` | PUT | *(reserved, not exposed as a command in v2 — see §5)* | Switches the selected node within a proxy group. Body is `{"name": "<node>"}` — the group is in the URL path, not the body |
| `/connections` | GET | `net status --verbose` (future), `doctor` | Active connection list (with a `connections` array); count is derived client-side as `connections.count` — there's no direct count field in the real response |
| `/connections` | DELETE | `net off`, `mode` switches | Optionally closes existing connections after a mode/proxy change so traffic doesn't continue routing under the old rule set — configurable, off by default to avoid disrupting in-flight downloads on every mode flip |

Note on `/proxies/{group}`: <cite index="4-1">a single PUT call against a proxy group is what actually performs node switching</cite> in the underlying API, confirming the endpoint and verb this table assumes.

## 4. Liveness check definition

"Liveness check" is referenced throughout the Full Specification (§4.1.1, and every atomic switch in the command specs) but not previously defined precisely. It is:

1. `GET /version` responds within the request timeout with a 2xx and a body containing a version string.
2. That version string matches the version the manager expects to have just launched (for `kernel use`/`start`/`restart`) — a mismatch means either a stale kernel process answered the port, or a race with a previous instance shutting down, and is treated as a failure requiring rollback.
3. For mode/network switches specifically, `GET /configs` is also called and the field being changed (`mode`, proxy settings) is confirmed to reflect the new value — a `PATCH` that returns 2xx but doesn't actually take effect (e.g. rejected internally with a warning-level log rather than an HTTP error) is still caught by this readback.

A liveness check that fails any of these three sub-checks triggers the rollback path described in §4.1.1 of the design doc.

## 5. Deliberate scope limits for this version

- **No node-level switching command yet.** `/proxies/{group}` PUT is wired into the client library since it's trivial once the client exists, but no `mihomo` command exposes it in this version — the design doc's command surface (§6) doesn't include per-node selection, only mode/network-level switching. Flagging this as a natural v3 addition (e.g. `mihomo proxy select <group> <node>`) rather than scope-creeping it into this pass.
- **No dashboard/UI hosting.** `external-ui` is a real mihomo feature but out of scope — <cite index="7-1">it's just a static file server with no security beyond CORS</cite>, and this remains a pure-CLI tool per the design doc's opening constraint.
- **Secret is never user-configurable in v2.** Since the manager always generates and owns the secret, there's no `--secret` flag anywhere in the command surface. If a future version supports attaching to an externally-managed kernel instance (not started by this tool), secret configuration would need to be added then.

## 6. Error mapping

| Client-library condition | CLI exit code | Example message |
|---|---|---|
| Connect timeout (kernel not listening) | `2` | `error: no kernel running — cannot change rule mode (fix: run 'mihomo start' first)` |
| Auth failure (401, wrong/stale secret) | `2` | `error: control API rejected the request — stored secret is stale (fix: run 'mihomo restart' to resync)` |
| Request timeout after connect (kernel hung) | treated as a running-process health failure, not the `8` source-verification code (which is reserved for fetch/presence checks) | `error: kernel process unresponsive — control API timed out after 5s (fix: 'mihomo restart', or check 'mihomo log' for a hung state)` |
| 2xx but readback mismatch (see §4, sub-check 3) | triggers rollback per §4.1.1 | staged-failure message as shown in each command spec |
| Version mismatch after switch (see §4, sub-check 2) | triggers rollback per §4.1.1 | `error: kernel switch aborted at 'liveness check' — new kernel process exited immediately` (or equivalent version-mismatch variant) |

## 7. Client library shape (implementation note, language-agnostic)

Regardless of the implementation language chosen for the CLI itself (see next step — project scaffolding), the client library should expose a small interface so command handlers never construct raw HTTP requests inline:

```
KernelClient
  .version() -> VersionInfo | ConnectError
  .getConfigs() -> Configs | ConnectError
  .patchConfigs(partial: ConfigsPatch) -> Result | ConnectError
  .getProxies() -> ProxyGroups | ConnectError
  .selectProxy(group: String, node: String) -> Result | ConnectError   // reserved, unused in v2
  .getConnections() -> ConnectionsSnapshot | ConnectError
  .closeConnections() -> Result | ConnectError
  .livenessCheck(expectedVersion: String?) -> LivenessResult
```

`livenessCheck` is a composed helper implementing the three sub-checks from §4 above, so every atomic-switch command in every group calls the same code path rather than reimplementing it — this is the single most important piece of shared logic in the whole tool, since it's what §4.1.1's rollback guarantee actually rests on.
