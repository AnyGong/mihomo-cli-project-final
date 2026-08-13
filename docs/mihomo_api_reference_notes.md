# mihomo Control-API Reference Notes

Sourced directly from the official mihomo documentation (`wiki.metacubex.one/en/api/`, fetched 2026-08-13). This supplements — and where more specific, supersedes assumptions in — `mihomo_control_api_integration_spec.md`. Only endpoints this project actually uses (or has reserved for future use) are detailed; the full API surface is much larger (logs, traffic, memory, DNS query, storage, debug/pprof) and is out of scope for this tool.

**Auth confirmed:** `Authorization: Bearer ${secret}` header, matching the integration spec's assumption exactly. No changes needed there.

**Live confirmation:** requirement-closure item #2 is closed for this project's current endpoint use. On 2026-08-13, a real mihomo process accepted `PATCH /configs` with `{"mode":"global"}`, `{"mode":"direct"}`, and `{"mode":"rule"}`; each request returned HTTP 204 and the changed value read back through `GET /configs`.

---

## Endpoints this project uses

### `GET /version`

Used by: `KernelClient.version()`, every `livenessCheck`.

Response fields:
- `meta` (bool) — whether this is a Meta build
- `version` (string) — version string

**Correction to `KernelClient.swift`'s current stub:** the `VersionInfo` struct already matches this exactly (`version: String`, `meta: Bool`) — no change needed, just confirmed correct.

### `GET /configs`

Used by: `mode status`, `net status`, `doctor`.

Response: JSON object of the current running configuration, including `port`, `socks-port`, `mixed-port`, `mode`, `log-level`, `allow-lan`, `ipv6`, `tun`, and other fields (not an exhaustive enumerated list in the docs — treat as an open-ended object and decode defensively, only pulling the fields this tool actually reads).

**Correction:** the current `Configs` struct only has `mode` and `mixedPort`. Real field names are kebab-case (`mixed-port`, `socks-port`, `log-level`, `allow-lan`), not camelCase — Swift's `JSONDecoder` needs `.convertFromSnakeCase` won't handle kebab-case automatically; use explicit `CodingKeys` instead.

### `PATCH /configs`

Used by: `mode rule|global|direct` (via `patchConfigs`).

Request body example from the docs: `{"mixed-port": 7890}`. By the same pattern, changing mode is `{"mode": "rule"}` (or `"global"` / `"direct"`). This specific field was live-confirmed on 2026-08-13 against a running mihomo instance: `rule`, `global`, and `direct` all returned 204 and read back through `GET /configs`.

Response: HTTP 204, no body. **Correction:** the current `patchConfigs` stub assumes some response to decode; there isn't one — success is "204, no body," failure is a non-204 status. `livenessCheck`'s config-readback sub-check (a follow-up `GET /configs`) is therefore not optional — it's the *only* way to confirm a `PATCH` actually took effect, since the `PATCH` response itself carries no confirmation.

### `GET /proxies`

Used by: `net status`, `doctor`.

Response: `proxies` object keyed by proxy/group name. Every entry has common fields (`name`, `type`, `udp`, `uot`, `xudp`, `tfo`, `mptcp`, `smux`, `alive`, `history`, `extra`, `interface`, `routing-mark`, `provider-name`, `dialer-proxy`). Policy groups (`Selector`, `URLTest`, `Fallback`, `LoadBalance`) additionally include `now` (currently selected node — absent for `LoadBalance`), `all` (member list), `testUrl`, `hidden`, `icon`, `emptyFallback`, `expectedStatus`, `fixed`.

**Correction:** `ProxyGroups` is currently an empty placeholder struct. This tool's `net status` only needs a small slice of this (group name + `now` + `all`, to show "which node is currently selected in which group") — decode only that subset rather than the full schema, since most of these fields (delay history, dialer-proxy, health-check config) are irrelevant to a status display.

**Related, narrower endpoint worth using instead for some cases:** `GET /group` returns *only* policy groups (not regular proxies), same object shape as a `/proxies/{name}` entry. If `net status` only ever needs to show policy groups (which is the case — individual leaf proxies aren't independently switchable in this tool's scope), `/group` is a better fit than filtering `/proxies` client-side.

### `PUT /proxies/{name}`

Reserved for the not-yet-exposed `mihomo proxy select` command (integration spec §5 — deliberately out of scope for v2's command surface).

Request body: `{"name": "NodeName"}` — note this selects a node *within* the group named by `{name}` in the URL path; it is not `/proxies/{group}/{node}` as a shorthand comment in the original integration spec loosely implied. **Correction, minor:** update that endpoint's documented request format when this command is eventually built (Layer "v3", not scheduled).

`DELETE /proxies/{name}` clears a fixed selection (not applicable to `Selector` groups) — also reserved, not currently used.

### `GET /connections`, `DELETE /connections`

Used by: `net off`, mode switches (optional connection-closing behavior), `doctor`.

`GET` response: `downloadTotal`, `uploadTotal`, `memory`, and a `connections` array (id, metadata, upload/download counters, start time, proxy chain, matched rule). **Correction:** the current `ConnectionsSnapshot` struct only has a `count` field — the real response has no direct "count" field; derive it client-side as `connections.count` after decoding the array, or just decode `connections: [ConnectionEntry]` and let callers take `.count` themselves.

`DELETE /connections` closes all connections, HTTP 204 no body — matches the integration spec's existing assumption exactly.

---

## Endpoints noted but intentionally not used

- **`POST /upgrade`** — mihomo has a *built-in* self-upgrade mechanism (optionally scoped with `?channel=`) that replaces the running binary in place. **This project deliberately does not use it.** The whole point of this tool's `kernel` command group is side-by-side multi-version management (install several versions, switch between them, keep "added time"/"last used" metadata per version) — mihomo's built-in `/upgrade` upgrades in place with no version history, which doesn't fit that model. Worth stating explicitly so a future implementer doesn't "simplify" `kernel check`/`kernel use` into a call to this endpoint and accidentally drop the multi-version feature.
- **`POST /restart`** — restarts the kernel process, reloading its config. Different from this tool's own `mihomo restart` command, which is a full stop/start of the *manager-launched subprocess* (potentially even swapping the binary via `kernel use` first). Not used directly, though it's worth knowing it exists as a lighter-weight alternative for a future "reload config without restarting the process" command, if that's ever wanted.
- **`/configs/geo`, `/upgrade/ui`, `/upgrade/geo`** — GEO database and dashboard-UI management. Out of scope; this tool doesn't manage GEO data or a bundled dashboard (§5 of the integration spec explicitly excludes hosting `external-ui`).
- **`/logs` (GET/WS), `/traffic`, `/memory`** — real-time streaming endpoints. Not used in v2's command surface; a future `mihomo net status --live` or similar could use `/traffic`, but nothing currently calls for it.
- **`/rules`, `/rules/disable`, `/providers/rules`, `/providers/proxies`** — rule/provider introspection and live-reload. Out of scope for the current command surface (this tool manages subscriptions as whole files, not individual rules/providers within them).
- **`/dns/query`, `/storage/*`, `/debug/*`** — unrelated to this tool's scope.

---

## Corrections to apply in code (Phase 2 implementation checklist)

- [x] `Configs` struct: add explicit `CodingKeys` mapping kebab-case JSON keys to camelCase Swift properties (`mixedPort` ↔ `"mixed-port"`, etc.), not just `mode`.
- [x] `patchConfigs`: confirm it does not attempt to decode a response body; success is bare HTTP 204.
- [x] `ProxyGroups`: decode only `name`, `now`, `all` per group — use `GET /group` instead of `GET /proxies` for this tool's actual use case (policy groups only).
- [x] `ConnectionsSnapshot`: replace the placeholder `count: Int` field with a decoded `connections: [ConnectionEntry]` array; derive count client-side.
- [x] `selectProxy(group:node:)`'s doc comment: request body is `{"name": "<node>"}` against `PUT /proxies/{group}`, not a body containing the group name.
