# ADR-014: WebSocket Transport Library Change — AnyEvent → Protocol::WebSocket

**Date**: 2026-09-01
**Status**: Accepted
**Deciders**: Kevin Adams
**Supersedes**: ADR-012 (Question 1 / library choice section only — the rest of ADR-012's design, method mapping, and auth decisions are unaffected and still in effect)

## Context

Less than 24 hours after v4.0.0 shipped, the first real user (#290) hit a hard
failure on every attempt to add a TrueNAS SCALE 25.04+ storage through the
Proxmox WebUI:

```
create storage failed: TrueNAS WebSocket connect to 192.168.69.92 failed:
AnyEvent::CondVar: recursive blocking wait attempted at TrueNAS.pm line 308
```

### Root cause (confirmed by direct reproduction, 2026-09-01)

ADR-012's live verification — every read call, a full `alloc_image`/
`free_image`/snapshot cycle, multipath, a REST-path regression check — was
all done by calling the plugin module's functions directly from standalone
Perl scripts. Every one of those scripts was the *only* thing in its process
using `AnyEvent`, so `_ws_connect`'s blocking `->recv()` was always the
outermost (and only) event-loop wait. That verification was real and correct
for what it tested — but it never once ran *inside the actual `pvedaemon`
process*, which is the only way a real user ever exercises this code.

`pveproxy` and `pvedaemon` are themselves built on `AnyEvent` as their core
reactor (Proxmox's own API server stack). When the WebUI's "Add Storage"
action calls into the plugin (`activate_storage` → `_ws_connect`), it runs
*inside* that daemon's already-active event loop. The plugin's own blocking
`->recv()` is a second, nested loop-wait on top of the daemon's own —
exactly what `AnyEvent` refuses to allow, by design, because nesting
blocking waits is genuinely unsafe with several backend implementations.

This was reproduced directly: `pvesm add` (a standalone CLI tool, its own
fresh process) did **not** trigger the bug — confirming the hypothesis.
Issuing the same request via the real REST API (`POST /api2/json/storage`
through `pveproxy`, matching exactly what the WebUI sends) reproduced the
exact reported error on the first try, on a real lab node (`pve03-hq`).

**This is not a one-off edge case or a race condition** — it fails on every
real invocation of the WebUI/API "Add Storage" path against any
WebSocket-transport host, unconditionally. `AnyEvent::WebSocket::Client`'s
blocking style cannot work inside `pveproxy`/`pvedaemon`, ever, regardless of
how carefully it's used.

## Decision

Replace the WebSocket transport implementation with **`Protocol::WebSocket::Client`
+ `IO::Socket::SSL`** — a plain, synchronous socket client with **zero event-loop
dependency of any kind**. `Protocol::WebSocket::Client` is purely a protocol
state machine: it encodes/decodes handshake and frame bytes via callbacks
(`write`/`read`/`connect`/`error`) and does no I/O itself. The plugin owns a
blocking `IO::Socket::SSL` handle directly and feeds bytes in/out via a
`select()`-with-timeout read loop (`_ws_pump`). Because this never touches
`AnyEvent` (or any other reactor) at all, there is no shared event-loop state
to conflict with `pveproxy`/`pvedaemon`'s own — nesting is structurally
impossible, not just carefully avoided.

This was ADR-012's original "Option A" alternative, set aside at the time in
favor of `AnyEvent::WebSocket::Client` specifically because the latter was
independently proven working by `boomshankerx`'s implementation. That
evidence was real, but incomplete — it (like this project's own initial
testing) never proved the blocking-`recv()` pattern safe *inside a daemon
that is itself built on the same event-loop library*. This ADR corrects that.

### What did NOT change

- `_api_ws`'s method-mapping logic (the REST-path-to-JSON-RPC translation
  table) — completely unchanged. Only `_ws_connect`/`_ws_call`'s internals
  changed; every call site above them is identical.
- The JSON-RPC envelope, auth call (`auth.login_with_api_key`), and every
  method-mapping decision from ADR-012 — all still correct and unaffected.
- `packaging/DEBIAN/control.j2`'s dependency list changes (`libanyevent-perl`
  / `libanyevent-websocket-client-perl` → `libprotocol-websocket-perl`;
  `libio-socket-ssl-perl` added explicitly since it's now used directly, not
  just transitively via `LWP::Protocol::https`), but nothing else about the
  package changes.

## Live re-verification (2026-09-01)

Re-ran the complete verification suite from ADR-012 against the new
implementation, against the same real hosts:

- Every read (query) call — pass
- Full `alloc_image`/`path`/`volume_size_info`/`free_image` write cycle
  against `.92` — pass, zero orphans
- Full snapshot cycle (`volume_snapshot`/`_info`/`_rollback`/`_delete`) —
  pass
- Multipath (`activate_volume`/`deactivate_volume`, real 2-path
  `dm-multipath` device) — pass
- **The actual bug reproduction, re-run against the fix**: same
  `POST /api2/json/storage` request via the real `pveproxy`/`pvedaemon` on
  `pve03-hq` that previously reproduced the error — now returns HTTP 200,
  storage created and confirmed `active`, plugin log shows clean transport
  detection and activation with no errors. This is the verification that
  actually matters for this ADR — everything else was already known-good
  from ADR-012 and was re-run to confirm the transport swap didn't regress it.

## Consequences

- `packaging/DEBIAN/control.j2` Depends: `libanyevent-perl` and
  `libanyevent-websocket-client-perl` removed; `libprotocol-websocket-perl`
  and `libio-socket-ssl-perl` added. Both confirmed apt-available on Debian
  trixie. CI's lint-job module install list updated to match.
- `$VERSION` bumped to `4.0.1` — this ships as a patch release fixing a
  release-day P1, not a new feature.
- **Process lesson, not just a code lesson**: standalone-script verification
  of plugin logic is necessary but not sufficient for a Proxmox storage
  plugin — it cannot catch bugs that only manifest from the plugin running
  inside `pveproxy`/`pvedaemon`'s own process. Any future transport-level or
  connection-lifecycle change to this plugin should be verified via a real
  `POST` to the local Proxmox REST API (or an actual WebUI action) on a lab
  node, not just direct module calls, before being considered proven.

## References

- ADR-012 (original WebSocket transport design — superseded in the library
  choice only, everything else stands)
- #290 (the bug report that triggered this ADR)
- [AnyEvent documentation on recursive condvar waits](https://metacpan.org/pod/AnyEvent) —
  the `->recv` "recursive blocking wait" guard is documented AnyEvent
  behavior, not a bug in AnyEvent itself
- `Protocol::WebSocket::Client` source (`/usr/share/perl5/Protocol/WebSocket/Client.pm`
  on Debian trixie) — confirmed I/O-agnostic, callback-driven design during
  implementation
