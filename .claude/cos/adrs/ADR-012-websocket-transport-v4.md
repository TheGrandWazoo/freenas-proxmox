# ADR-012: WebSocket JSON-RPC 2.0 Transport for v4.0.0 (Rivendell)

**Date**: 2026-08-29
**Status**: Accepted (2026-08-31) — design decided and fully live-verified: every read and write API call the WebSocket transport makes has been confirmed against real TrueNAS SCALE hosts (`.91`, `.92` across 25.10.x and 25.04.2.6). **Question 1 (library choice) superseded by [ADR-014](ADR-014-websocket-transport-library-change.md) 2026-09-01** — `AnyEvent::WebSocket::Client` broke in production (#290); everything else in this ADR stands.
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
a live server-side bug. Full findings below, live-verified against `.91` and
`.92` across three different TrueNAS versions including 25.04.2.6 specifically
([[project_truenas_lab_versions]]) — see Live Verification below.

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
- **Auth — CONFIRMED live against `.91` and `.92` (both TrueNAS-25.10.6)
  2026-08-29/30**: `auth.login_ex` with `mechanism: "API_KEY_PLAIN"`
  **requires** a `username` field (server-side Pydantic validation rejects its
  absence: `"Field required"`) — but this plugin doesn't currently ask users
  for a TrueNAS username anywhere in `storage.cfg`, only an API key. Tested
  `username: "root"` against two different TrueNAS boxes with two different
  keys: on `.91` it **succeeded** (`response_type: "SUCCESS"`, full
  `user_info` showing `pw_name: "root"`, `FULL_ADMIN` role — that key really is
  tied to root) — on `.92` it **failed** (`{"response_type":"AUTH_ERR"}`, a
  JSON-RPC-level *success* envelope whose payload signals auth failure, not a
  JSON-RPC `error` — a real protocol gotcha worth remembering either way).
  `login_ex` isn't broken; it works correctly given the right username, but
  **which username owns a given API key varies per TrueNAS install** and this
  plugin has no way to know or ask for it today. The legacy
  **`auth.login_with_api_key`** (single positional `[api_key]` param, no
  username needed at all) authenticated correctly against *both* boxes
  regardless of which account created the key. It's deprecated in TrueNAS 26
  and slated for removal in 27, but is proven working today, matches this
  plugin's existing "just an API key" config model, and is what
  `boomshankerx`'s independent implementation and the `acme.sh` deploy hook
  both use in practice. **Recommendation: build against `auth.login_with_api_key`
  for the initial v4.0.0 cut** — not because `login_ex` is unreliable, but
  because using it correctly would require adding a username field to
  `storage.cfg` that doesn't exist today, a config-schema change out of scope
  for this ADR. Revisit `login_ex` if/when TrueNAS 27's removal of
  `login_with_api_key` forces the issue.
- **Envelope**: vanilla JSON-RPC 2.0 — `{"jsonrpc":"2.0","id":N,"method":...,
  "params":[...]}`, response `{"id":N,"result":...}` or
  `{"id":N,"error":{"code":...,"message":...}}`. No batching. `id`-based
  correlation, so multiple in-flight requests are legal, but the server caps
  concurrency and returns error `-32000` ("too many concurrent calls") past
  the limit — our per-invocation call pattern is low-concurrency enough that
  this shouldn't bite us, but the client needs to handle the error rather than
  assume it can't happen.
- **Method mapping — CONFIRMED live against `.92` (TrueNAS-25.10.3.1) 2026-08-29**,
  all 8 endpoint families, all synchronous/non-job calls (no job-polling logic
  needed for anything this plugin does today). Every call below returned real
  data with no errors using `scripts/truenas-ws-diag.pl`:

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
- **Known live bug, NAS-135643 — CLOSED, confirmed fixed on 25.04.2.6**:
  TrueNAS Jira NAS-135643 documented `iscsi.target.query` over JSON-RPC
  throwing a server-side `AttributeError` in the version-adapter layer on
  SCALE 25.04.0 (didn't reproduce on 24.10.2.1 either). Confirmed clean on
  `.92` (TrueNAS-25.10.3.1, 2026-08-29), again on both `.91` and `.92` after
  both converged to TrueNAS-25.10.6 (2026-08-30, `.91` with real
  production-scale data — 2 targets, 9 extents, 9 targetextents), **and
  finally on `.92` rebuilt to TrueNAS-25.04.2.6 specifically (2026-08-30)** —
  the exact SCALE minor version the bug was originally filed against, just two
  patch levels later. `iscsi.target.query` returned a real target cleanly, no
  error. This closes the gap this ADR previously flagged (no 25.04.x node in
  the lab) — confirmed fixed by 25.04.2, not just inferred from newer
  versions.
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

### Question 1: WebSocket client library — DECIDED, then SUPERSEDED

> **Superseded 2026-09-01 — see [ADR-014](ADR-014-websocket-transport-library-change.md).**
> `AnyEvent::WebSocket::Client`'s blocking `->recv()` cannot run inside
> `pveproxy`/`pvedaemon` (themselves built on `AnyEvent`) without nesting
> event loops, which `AnyEvent` refuses by design — confirmed by a real user
> (#290) on the very first real WebUI use, one day after v4.0.0 shipped. The
> library was replaced with `Protocol::WebSocket::Client` + `IO::Socket::SSL`
> (zero event-loop dependency). Left as-written below per this project's ADR
> rule against editing an ADR's original decision text — this note is the
> pointer forward, not a correction of the historical record. Every other
> decision in this ADR (auth, method mapping, envelope) is unaffected.

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

## Live verification (2026-08-29/30, against `.91` and `.92`, three TrueNAS versions)

Built `scripts/truenas-ws-diag.pl` — a standalone, read-only diagnostic (not part
of the packaged plugin) that connects via `AnyEvent::WebSocket::Client`,
authenticates, and exercises every method in the mapping table above. Ran it
from pve01-hq four times as the lab nodes moved:

| Run | Host | TrueNAS version | Result |
|---|---|---|---|
| 2026-08-29 | `.92` (192.168.69.92) | `TrueNAS-25.10.3.1` | All 8 method families OK, `login_ex`/root → `AUTH_ERR`, `login_with_api_key` OK |
| 2026-08-30 | `.92` (192.168.69.92) | `TrueNAS-25.10.6` (upgraded) | Re-ran after the point-release bump — identical results |
| 2026-08-30 | `.91` (172.31.69.91) | `TrueNAS-25.10.6` (upgraded straight past Fangtooth) | All 8 method families OK against real production-scale data (2 targets, 9 extents); `login_ex`/root → **SUCCESS** this time — see Auth bullet above for why that differs from `.92` |
| 2026-08-30 | `.92` (192.168.69.92) | `TrueNAS-25.04.2.6` (fresh rebuild, per-lab-role revision — see [[project_truenas_lab_versions]]) | All 8 method families OK against a wizard-created target/portal; `iscsi.target.query` (the NAS-135643 method) confirmed clean on this exact minor version — **closes the gap** |

- **Auth resolved with more nuance than the first pass concluded** — see the
  Auth bullet above. `login_ex` works correctly per-key; `login_with_api_key`
  is still the right implementation choice because it works regardless of
  which account owns the key, with no username field needed. One more
  auth-flow gotcha found on `.92`'s fresh 25.04.2.6 install: retrying
  `auth.login_ex` a second time on the *same* WebSocket connection after a
  first failed attempt threw a raw, unhandled `RuntimeError('AUTH: unexpected
  authenticator run state. Expected: START')` — server-side state left over
  from the first attempt, not a clean rejection. Didn't block anything (the
  diagnostic's third attempt, `login_with_api_key`, still succeeded
  afterward on the same connection), but it reinforces the recommendation:
  the real implementation should call `login_with_api_key` directly, never
  attempt `login_ex` speculatively first on a connection that might retry.
- Also hit a real Perl gotcha worth documenting for implementation: `JSON`'s
  `decode_json` turns a JSON `true`/`false` into a blessed `JSON::PP::Boolean`
  object, not a plain `1`/`0` — `ref()` on it is truthy, so a naive
  `!ref($x) || ...` truthiness check will try to hash-dereference it and die.
  Check `ref($x) eq 'HASH'` explicitly before assuming a non-hash result is a
  plain scalar.
- **Every method-mapping call succeeded on every run** — `iscsi.global.config`,
  `iscsi.portal.query`, `iscsi.target.query`, `iscsi.extent.query`,
  `iscsi.targetextent.query`, `pool.dataset.query`, `zfs.snapshot.query`,
  `core.ping` all returned clean data with real values, no method-not-found or
  schema errors, across a near-empty test box, a box with real
  production-scale iSCSI config, and a fresh from-scratch install.
- **NAS-135643 confirmed fixed**, including on 25.04.2.6 specifically (see
  bullet above) — no longer a hard blocker, and no longer just inferred from
  newer versions.

This resolves every "unconfirmed, verify against live lab" item this ADR
originally flagged, including the one that was still an acknowledged gap as of
2026-08-30 morning: `.92` was rebuilt from scratch to TrueNAS-25.04.2.6
specifically (Kevin's own infrastructure work, not something drivable via
API) to close it. No remaining live-verification gaps for this ADR. The lab
plan has also been revised for future testing: `.90`/`.91` now stay on latest
stable (pseudo-production baseline), and `.92` is the designated
dynamic/development node for whatever version-specific testing comes up next
([[project_truenas_lab_versions]]).

## Consequences

- `libanyevent-websocket-client-perl` (pulls in `libanyevent-perl`) becomes a new
  package dependency in `packaging/DEBIAN/control.j2` for the v4 dist track only
  (v3.x stays REST-only, per ADR-009's version matrix — this is a `v4`-dist
  concern, doesn't affect existing stable users).
- Auth implementation should target `auth.login_with_api_key`, not `auth.login_ex`
  — confirmed live, see above. No plugin config changes needed (still just an API
  key, same as REST today).
- No job-polling logic is needed for v4.0.0's initial scope (all 8 endpoint
  families are synchronous, confirmed both by docs and live testing).
- `truenas_ssl_verify => 0` behavior (self-signed cert support) carries over
  unchanged — `AnyEvent::WebSocket::Client` supports disabling cert verification
  the same way the current `LWP::UserAgent` path does (used as `ssl_no_verify`
  in the diagnostic script, same live test).
- Watch for the `JSON::PP::Boolean` truthiness gotcha (above) when writing the
  real `_api_ws()` implementation — a boolean JSON-RPC result is common (e.g.
  `pool.dataset.delete` returns one) and needs `ref() eq 'HASH'` guarding.
- #249 (per-variant dispatch) stays deferred past v4.0.0 — tracked as possible
  v4.1/v5.0 scope, see Question 2 above.
- **`TrueNASMultipath.pm` needs no separate WebSocket work — CONFIRMED live
  2026-08-31, not just by code inspection.** It calls
  `PVE::Storage::Custom::TrueNAS::_api(...)` directly (a fully-qualified sub
  call, not an overridable method) for every operation except its four
  multipath-specific overrides (`path`, `qemu_blockdev_options`,
  `activate_volume`, `deactivate_volume`, none of which touch the TrueNAS API
  directly). Ran a full `alloc_image` → `activate_volume` → `path` →
  `deactivate_volume` → `free_image` cycle against `.92` with zero code
  changes to `TrueNASMultipath.pm`: `iscsiadm` logged into both configured
  portals, `multipathd` built a real `/dev/mapper/<wwid>` device with 2 active
  paths (`multipath -ll` showed both `active ready running` under one
  `multibus` group), and teardown cleanly flushed/logged out/removed
  everything. Notably, TrueNAS's own `.92` only has *one* portal object
  (listening on `0.0.0.0`) rather than the two per-IP portals the
  CORE-vs-SCALE table in `docs/architecture.md` §9 describes as the SCALE
  requirement — `iscsiadm` logging into two different IPs against that same
  `0.0.0.0`-listening portal still produced two genuine, independent paths,
  since the Linux initiator/target don't care about TrueNAS's internal
  portal-object bookkeeping, only the actual IP:port endpoints reached.
  Documented in `docs/architecture.md` §9 (added 2026-08-30, alongside
  README/docs coverage for the multipath package that had been missing since
  its v3.2.0 release; live-confirmation note added 2026-08-31).

## Implementation branch

Development for this ADR happens on the branch created 2026-08-29 as
`release/4.x` (branched from what was then `release/3.x`) — CI resolves pushes
there to `<VERSION>~alpha+<sha>` / `truenas-proxmox-snapshots`. Standing it up
surfaced one real, previously-dormant CI bug worth noting here since it's a
direct consequence of this ADR's work existing on its own branch: the
"Publish to GitHub Pages testing dist" step ran for both `testing` and
`development` channel builds and did `rm -rf pool/testing` first, so the first
push to this branch briefly overwrote the public testing dist with an
unrelated alpha build. Fixed in `build.yml` (restricted that step to
`channel == 'testing'` only) and verified live.

**2026-08-30 — renamed to `next`** as part of [ADR-013](ADR-013-branching-strategy.md)'s
role-based branch naming: `release/N.x` names are now reserved exclusively for
already-superseded majors, so the in-progress v4.0.0 work moved to the fixed
name `next` (and the old `release/3.x` became `main`). Same content, same
history, just a new name — `$VERSION` in `TrueNAS.pm` stays at the `main`
branch's value (`3.2.5`) until real implementation code lands here, per the
branch's own alpha-channel versioning.

**2026-08-30 (later same day) — first real implementation landed.** `_api_ws`,
`_ws_connect`, `_ws_call`, and `_transport()` added to `TrueNAS.pm` on `next`,
matching this ADR's decided design exactly (`AnyEvent::WebSocket::Client`,
`auth.login_with_api_key`, hand-built JSON-RPC envelope). `$VERSION` bumped to
`4.0.0`. Live-verified end-to-end against `.92` (TrueNAS-25.04.2.6) through the
actual plugin module (not just `scripts/truenas-ws-diag.pl`) — transport
auto-detection, `_api_global`, portal/target queries, and the single-ID
lookup mapping used by `path()`/`qemu_blockdev_options()` all confirmed
working. This exercises every *read* call the plugin makes; the *write* path
(create/delete param shapes) is implemented but not yet independently
live-tested — see the file's own header warning and re-verify before trusting
`alloc_image`/`free_image`/snapshot operations in production on SCALE 25.04+.

One real bug caught and fixed during this integration pass: `_transport()`'s
first draft checked `/system/product_type eq 'SCALE'` to distinguish CORE from
SCALE, but that endpoint returns the license tier (e.g. `"COMMUNITY_EDITION"`),
not the product family — it was always false, so transport detection always
fell back to REST regardless of actual version. Fixed by parsing the
`/system/version` string's major-version magnitude instead (SCALE's calendar
versioning is unambiguously >= 24; CORE has only ever used 11.x-13.x).

**2026-08-31 — write path live-tested for the first time.** Ran a full
`alloc_image` → `path` → `volume_size_info` → `free_image` cycle against `.92`
with a disposable fake VMID, calling the plugin module directly (not deployed
to any Proxmox node — see the risk note in Implementation branch above). Found
and fixed two real bugs, same "string vs integer" class of issue that's a
running theme throughout the REST implementation:

- `iscsi.target.delete` and `iscsi.targetextent.delete` were passed a raw
  regex-captured id (a Perl string) — Pydantic rejects it without `int()`.
- `iscsi.extent.delete(id, remove=False, force=False)` is **positional**, not
  `(id, {force=>bool})` — REST's `{force=>true}` body was landing in position
  2, which the API validates as a boolean field named `remove`, not `force`.
  Fixed to unpack positionally, with `remove` always `false` (REST's DELETE
  never asked for that — `free_image` deletes the underlying zvol separately).

After the fix: a full cycle leaves zero orphaned targets, extents,
targetextents, or datasets on TrueNAS — confirmed by querying `.92` directly
before and after, which means `pool.dataset.create` and `pool.dataset.delete`
are now confirmed working too (the latter's `[id, {recursive,force}]` shape,
sourced from documented API research rather than guesswork, checked out on
the first try).

**2026-08-31 (same day) — zfs.snapshot.* tested, write path fully closed.**
Ran a full `volume_snapshot` → `volume_snapshot_info` → `volume_snapshot_rollback`
→ `volume_snapshot_delete` cycle against a disposable volume on `.92`. All four
succeeded on the first try, no param-shape bugs found — `zfs.snapshot.create`'s
plain-object param, `zfs.snapshot.query`'s dataset filter, `zfs.snapshot.rollback`'s
positional `(id, options)`, and `zfs.snapshot.delete`'s single positional id
all matched what was implemented. Confirmed zero orphaned snapshots or volumes
afterward.

**Every API call this plugin makes over the WebSocket transport is now
live-verified against a real TrueNAS SCALE host.** The "write path not yet
tested" warning is fully closed — nothing about `_api_ws`'s method mapping
remains unverified. `TrueNAS.pm`'s own header comment has been updated to
match. This ADR's live-verification bar (Context, above) is now completely
satisfied — **Kevin marked it Accepted 2026-08-31.**

**2026-08-31 — REST-path regression check.** `_api()` becoming a dispatcher
means every call in the file now passes through `_transport()` first,
including on hosts that only ever used REST before this ADR — a real
regression risk `_api_rest` itself is unchanged, but nothing had actually
confirmed the dispatcher wrapper doesn't break it. Ran the full read/write/
snapshot suite against `.90` (TrueNAS CORE, a real production box with
existing VMs — `proxmox-vm-100`/`proxmox-vm-103` already in use, not a clean
test box like `.92` was). `_transport()` correctly detected `rest`; every
operation succeeded with zero regressions, confirmed back to the original 3
targets and 4 volume datasets afterward with no side effects on the real
data. CORE will never get WS support (out of scope, REST forever per #243),
so this is the definitive regression check for that side of the dispatcher —
no SCALE < 25.04 host currently exists in the lab to separately check that
branch (see [[project_truenas_lab_versions]]), but the code path is identical
regardless of which pre-25.04 condition routes there.

## References

- ADR-009 (established v4.0.0 = WebSocket, this ADR is the "how")
- ADR-011 (apt-components/separate-package precedent, relevant to Question 2)
- #243 (tracking issue, full research trail in comments)
- #205 (original 2025-04-20 bug report; the `boomshankerx`/`mir07` design
  discussion that produced the prior art above)
- [[project_truenas_lab_versions]] (test lab plan for verifying the unconfirmed items above)
- `scripts/truenas-ws-diag.pl` (this repo — the read-only diagnostic tool used for the 2026-08-29 live verification above)
- `docs/architecture.md` §9 (multipath's inheritance of this ADR's transport work, and the multipath docs added 2026-08-30)
- `next` branch (implementation work for this ADR lives here, renamed from `release/4.x` 2026-08-30; see Implementation branch above)
- `perl5/PVE/Storage/Custom/TrueNAS.pm` on `next` (`_api_ws`/`_ws_connect`/`_ws_call`/`_transport` — the actual implementation, first landed 2026-08-30)
- ADR-013 (branching strategy — role-based branch naming, why this ADR's branch was renamed)
- `truenas/truenas_jsonrpc` (protocol spec) and `truenas/api_client` (Python reference client) on GitHub
- [boomshankerx/proxmox-truenas](https://github.com/boomshankerx/proxmox-truenas) (independent AGPL-3.0 successor project, reference only — see Prior Art above)
- TrueNAS Jira NAS-135643 (bug in `iscsi.target.query` over JSON-RPC on SCALE 25.04.0 — confirmed fixed by 25.04.2.6, see Live Verification above)
