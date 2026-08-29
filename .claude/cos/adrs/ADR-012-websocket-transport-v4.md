# ADR-012: WebSocket JSON-RPC 2.0 Transport for v4.0.0 (Rivendell)

**Date**: 2026-08-29
**Status**: Draft — design questions decided, pending live-lab protocol verification before Accepted
**Deciders**: Kevin Adams

## Context

ADR-009 established that v4.0.0 must add TrueNAS SCALE's WebSocket JSON-RPC 2.0
transport, since SCALE 25.04 deprecates the REST API and SCALE 26.x removes it
entirely. TrueNAS CORE 13.x has no plans to move off REST, so v4.0.0 must speak
**both** transports and pick one per storage based on the detected TrueNAS variant
and version — exactly the question #243 opened and #249 anticipated.

This ADR is the design/scoping pass Kevin called for before any implementation
starts (#243, comment 2026-08-23). Research sources: TrueNAS's official API docs
(api.truenas.com, versioned per release), the `truenas/api_client` and
`truenas/truenas_jsonrpc` reference repos, the `acme.sh` `truenas_ws.sh` deploy
hook (a real, working non-Python client), and a TrueNAS forum thread confirming
a live server-side bug. Full findings below; anything not directly confirmed
against a live TrueNAS box is flagged explicitly and should be checked against
the lab's `.91`/`.92` nodes as they move through Fangtooth → Goldeneye
([[project_truenas_lab_versions]]) before this ADR is marked Accepted.

### Current REST implementation (baseline)

`TrueNAS.pm` is 813 lines and calls exactly 8 endpoint families through one
`_api($scfg, $method, $path, $data)` helper (`LWP::UserAgent`, Bearer token,
`/api/v2.0$path`): `iscsi/global`, `iscsi/portal`, `iscsi/target`,
`iscsi/targetextent`, `iscsi/extent`, `service/reload`, `pool/dataset`,
`zfs/snapshot`. The plugin has no persistent daemon — every `pvesm`/`qm`
invocation is a fresh process, so `_api`'s cached `$state` (UA object, token,
global config) lives only for that one invocation. This matters for transport
design: a WebSocket connection does not need to survive across CLI invocations,
only across the handful of calls within one.

### Confirmed JSON-RPC 2.0 protocol facts

- **Endpoint**: `wss://<host>/api/current` (or pin a version: `/api/v25.04`).
  Plain `ws://` works but the server **auto-revokes any API key submitted over
  it** — TLS is mandatory in practice, same posture as today's REST/HTTPS.
- **Auth**: `auth.login_ex` with `mechanism: "API_KEY_PLAIN"` is the
  forward-compatible call for a plugin scoped at SCALE 25.04+. The older
  `auth.login_with_api_key` still works but is deprecated in TrueNAS 26 and
  slated for removal in 27 — not worth building against for a v4.0 plugin.
  **Unconfirmed**: the exact full request/response JSON body for `login_ex`
  couldn't be pulled from a rendered doc page — verify against a live
  Fangtooth/Goldeneye box (`.91`/`.92`) or `core.get_methods` before coding.
- **Envelope**: vanilla JSON-RPC 2.0 — `{"jsonrpc":"2.0","id":N,"method":...,
  "params":[...]}`, response `{"id":N,"result":...}` or
  `{"id":N,"error":{"code":...,"message":...}}`. No batching. `id`-based
  correlation, so multiple in-flight requests are legal, but the server caps
  concurrency and returns error `-32000` ("too many concurrent calls") past
  the limit — our per-invocation call pattern is low-concurrency enough that
  this shouldn't bite us, but the client needs to handle the error rather than
  assume it can't happen.
- **Method mapping** (all 8 of our endpoint families, all confirmed
  **synchronous, non-job** calls — no job-polling logic needed for anything we
  use today):

  | REST (current) | JSON-RPC method |
  |---|---|
  | `GET /iscsi/target` | `iscsi.target.query` |
  | `POST /iscsi/target` | `iscsi.target.create` |
  | `DELETE /iscsi/target/id/{id}` | `iscsi.target.delete` |
  | `GET /iscsi/extent` | `iscsi.extent.query` |
  | `POST /iscsi/extent` | `iscsi.extent.create` |
  | `DELETE /iscsi/extent/id/{id}` | `iscsi.extent.delete` |
  | `GET/POST/DELETE /iscsi/targetextent` | `iscsi.targetextent.{query,create,delete}` |
  | `GET /iscsi/portal` | `iscsi.portal.query` |
  | `GET /iscsi/global` | `iscsi.global.config` |
  | `POST /service/reload` | `service.reload` |
  | `POST/DELETE/GET /pool/dataset` | `pool.dataset.{create,delete,query,get_instance}` |
  | `POST/DELETE /zfs/snapshot`, rollback | `zfs.snapshot.{create,delete,rollback}`, `zfs.snapshot.query` |

- **Keepalive**: `core.ping` exists; exact server timeout unconfirmed — client
  should use a conservative, configurable interval rather than assuming a
  specific value.
- **Known live bug**: TrueNAS Jira **NAS-135643** — `iscsi.target.query` over
  JSON-RPC on SCALE 25.04.0 threw a server-side `AttributeError` in the
  version-adapter layer, reported by someone building a similar ZFS-over-iSCSI
  plugin. Did not reproduce on 24.10.2.1. **Must be verified against our own
  Fangtooth (25.04) lab node before this ADR is accepted** — `iscsi.target.query`
  is load-bearing for nearly every operation this plugin does.
- No official/upstream Perl implementation exists. `truenas/api_client`
  (Python, official, not on PyPI) and `truenas/truenas_jsonrpc` (protocol spec,
  language-agnostic, in `ARCHITECTURE.md`) are the best official reference
  material — but see Prior Art below for a real, independent Perl implementation
  found after this initial research pass.

## Prior art (found during scoping, 2026-08-29)

Issue #205 (2025-04-20, closed as stale 2025-09) is the original REST-deprecation
bug report, filed before #243 existed. Its comment thread turned into a live design
session between a community member (`boomshankerx`) and another contributor
(`mir07`) working through this exact problem in public. Kevin participated early
(2025-04-27 to 2025-05-01) but was not present for what followed:

- `boomshankerx` built a working alpha (2025-05-02) using `AnyEvent` +
  `AnyEvent::WebSocket::Client` + `JSON::RPC2::Client` (the last installed via
  `cpanm`, not apt — Debian's `libjson-rpc-perl` package is an unrelated module,
  not `JSON::RPC2::Client`).
- Deliberately did **not** fork this repo ("I don't want to dishonor
  @TheGrandWazoo and @mir07 by hijacking the project") and instead started
  **[boomshankerx/proxmox-truenas](https://github.com/boomshankerx/proxmox-truenas)**,
  same AGPL-3.0 license, explicitly crediting this project as its origin.
- That project is now mature and independently maintained: 154 stars, 119
  releases over 15+ months, automated `release-please` pipeline, last shipped
  2026-08-17. Its "Native" plugin targets TrueNAS 25.10+ over the WebSocket
  JSON-RPC API — the same problem #243 tracks.
- Also referenced: a second, architecturally different fork
  (`Jonah-May-OSS/truenas-proxmox`) that shells out to TrueNAS's own `midclt`
  CLI over SSH instead of a native WebSocket client — reintroduces the SSH+root
  dependency this project's v3.0 rewrite deliberately removed. Not pursued here
  for that reason.

**Decision on direction (Kevin, 2026-08-29): keep this project independent.**
`proxmox-truenas` is used as a reference to validate approach and tooling
choices where useful, not as a dependency or merge source. This resolves
Question 1 below with real-world evidence rather than a cold guess.

## Decision

### Question 1: WebSocket client library — DECIDED

**`AnyEvent::WebSocket::Client`** (`libanyevent-websocket-client-perl` 0.55-1,
apt-available on Debian trixie, depends on `libanyevent-perl` 7.170, also
apt-available) for the transport, used in blocking style (condvar `->recv`)
to match the plugin's existing per-invocation synchronous lifecycle — no
persistent event loop needed, same as today's one-shot `LWP::UserAgent` calls.

**No dedicated JSON-RPC library.** `boomshankerx` needed `JSON::RPC2::Client`
via `cpanm` because Debian's `libjson-rpc-perl` package doesn't provide that
module. We don't need either: the JSON-RPC 2.0 envelope is a plain hash
(`{jsonrpc=>"2.0", id=>$n, method=>..., params=>...}` out,
`{result=>...}`/`{error=>...}` back) that the plugin can build and parse with
the `JSON` module it already depends on for the REST path. This keeps the new
dependency surface to exactly one package (`libanyevent-websocket-client-perl`)
beyond what the plugin already ships with, and avoids the one piece of
`boomshankerx`'s stack that isn't cleanly apt-packageable — a real constraint
for this project given the "no CPAN, no patches, apt-installable" bar
CLAUDE.md holds it to.

This was previously framed as a choice between hand-rolling `Protocol::WebSocket`
and adopting the heavier `Mojolicious` stack. Both are superseded by the above —
`AnyEvent::WebSocket::Client` is proven working against real TrueNAS SCALE
25.04–25.10 JSON-RPC servers by an independent, still-shipping implementation,
which neither untested alternative could claim.

### Question 2: Act on #249 (per-variant dispatch) now, or keep one file? — DEFERRED

**Decision (Kevin, 2026-08-29): defer.** v4.0.0 ships with Option B — a
transport-dispatch layer inside `TrueNAS.pm` (`_api()` becomes a thin dispatcher
to `_api_rest()` / `_api_ws()` based on cached `product_name`+version detection,
same caching pattern `_api_global` already uses). No file split for this release.

`TrueNAS.pm` is already at 813 lines — past the 800-line trigger #249 itself set
for revisiting, and WebSocket-vs-REST is exactly the "new CORE/SCALE divergence
forcing if/else branching" #249 described — but bundling a file-split refactor
into an already-large, protocol-novel transport change adds risk without adding
correctness. The dispatch-layer approach keeps v4.0.0's diff smaller and the
transport work reviewable on its own.

The eventual split (`TrueNAS-Scale.pm`/`TrueNAS-Core.pm`, per #249, following the
same "separate plugin per divergent capability" pattern ADR-011 established for
multipath) is now explicitly framed as **future major-version scope — v4.1 or
v5.0** — once the WebSocket path has shipped and stabilized and it's clear how
much SCALE-specific logic actually diverges beyond just the transport. Kevin has
also floated pairing that refactor with detaching this repo's GitHub fork
relationship ([[project_fork_detach]]) — i.e. a version where the codebase has
diverged enough from both its original fork parent *and* its own v3.x REST-only
shape that it's fair to call it a clean break rather than an incremental step.
Both are speculative future-version ideas, not commitments — revisit once
v4.0.0's WebSocket transport is actually shipped.

## Consequences

- `libanyevent-websocket-client-perl` (pulls in `libanyevent-perl`) becomes a new
  package dependency in `packaging/DEBIAN/control.j2` for the v4 dist track only
  (v3.x stays REST-only, per ADR-009's version matrix — this is a `v4`-dist
  concern, doesn't affect existing stable users).
- Auth call shape (`auth.login_ex`/`login_with_api_key`), the full method-mapping
  table, and the NAS-135643 bug all still need direct verification against the
  lab's Fangtooth/Goldeneye nodes (`.91`/`.92`, [[project_truenas_lab_versions]])
  before implementation starts in earnest — several protocol details above are
  sourced from docs/forums/a third party's implementation, not yet confirmed
  against a live TrueNAS instance from this codebase.
- No job-polling logic is needed for v4.0.0's initial scope (all 8 endpoint
  families are synchronous per-the-docs) — keeps the first implementation
  smaller than originally feared.
- `truenas_ssl_verify => 0` behavior (self-signed cert support) carries over
  unchanged — `AnyEvent::WebSocket::Client` supports disabling cert verification
  the same way the current `LWP::UserAgent` path does.
- #249 (per-variant dispatch) stays deferred past v4.0.0 — tracked as possible
  v4.1/v5.0 scope, see Question 2 above.

## References

- ADR-009 (established v4.0.0 = WebSocket, this ADR is the "how")
- ADR-011 (apt-components/separate-package precedent, relevant to Question 2)
- #243 (tracking issue, full research trail in comments)
- #205 (original 2025-04-20 bug report; the `boomshankerx`/`mir07` design
  discussion that produced the prior art above)
- [[project_truenas_lab_versions]] (test lab plan for verifying the unconfirmed items above)
- `truenas/truenas_jsonrpc` (protocol spec) and `truenas/api_client` (Python reference client) on GitHub
- [boomshankerx/proxmox-truenas](https://github.com/boomshankerx/proxmox-truenas) (independent AGPL-3.0 successor project, reference only — see Prior Art above)
- TrueNAS Jira NAS-135643 (live 25.04.0 bug in `iscsi.target.query` over JSON-RPC)
