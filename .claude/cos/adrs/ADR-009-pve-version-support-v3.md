# ADR-009: PVE Version Support Matrix — v3.x and v4.0 Versioning Strategy

**Date**: 2026-05-31  
**Status**: Draft  
**Deciders**: Kevin Adams  
**Supersedes**: ADR-008 (pending acceptance of this ADR)

## Context

ADR-008 established the PVE version support matrix for v3.0. Three things emerged
during v3.0 development that require revised decisions:

1. **PVE 9 confirmed working** — pve01-hq was upgraded to PVE 9.2.3. One blocking
   bug was found (#266, `lun` integer type in QEMU blockdev JSON) and fixed by
   overriding `qemu_blockdev_options` in TrueNAS.pm.

2. **`api()` version conflict** — PVE 8 has `APIVER = 11`; PVE 9 has `APIVER = 14`.
   A single `api()` return value cannot satisfy both without warning (return 11)
   or fatally failing on PVE 8 (return 14). The warning is cosmetic and deferred.

3. **WebSocket API scope** — TrueNAS SCALE 25.04+ exposes a new JSON-RPC 2.0
   WebSocket API alongside the REST API. This is a new transport layer, not an
   incremental improvement. It warrants a major version bump when adopted.

4. **ADR-008 stated `volume_snapshot*` must ship in v3.0** — deferred to v3.1 (#234).

## Decision

### Version → PVE support mapping

| Version | PVE support | TrueNAS API | Notes |
|---------|------------|-------------|-------|
| v3.0.x | PVE 8.x + PVE 9.x | REST (v2.0) | `api()` = 11; cosmetic warning on PVE 9 |
| v3.1.x | PVE 9.x only | REST (v2.0) | `api()` bumped to PVE 9 APIVER; PVE 8 dropped |
| v4.0.x | PVE 9.x+ | WebSocket JSON-RPC 2.0 | New transport; genuine breaking change |

### Why v3.1 drops PVE 8 (not v4.0)

Dropping an EOL'd host platform is a support boundary decision, not a behavior
or API change. Users on PVE 8 stay on v3.0.x, which continues to work. The
plugin's `storage.cfg` format, TrueNAS API calls, and iSCSI behavior are
unchanged. Minor version bump is appropriate.

**PVE 8 EOL: 2026-08-31.** v3.1 must ship before that date so users have time
to migrate to PVE 9 before their platform is unsupported.

### Why v4.0 for WebSocket API

WebSocket JSON-RPC 2.0 is a fundamentally different transport layer. Adopting it
may require dropping or conditionally supporting the REST API for newer SCALE
versions, changing how the plugin establishes connections, and potentially
branching code paths per TrueNAS variant. This is an architectural change that
warrants a major version, not a minor one.

### v3.0.x specifics

- `api()` returns `11` — works on PVE 8 (exact match) and PVE 9 (within APIAGE range)
- PVE 9 emits "older storage API, upgrade recommended" — cosmetic, documented, expected
- `qemu_blockdev_options` override present — workaround for PVE `Plugin.pm` bug (#266)
  - Remove when Proxmox fixes `lun => int($3)` in their code (see TrueNAS.pm comment)
- `volume_snapshot*` not implemented — deferred to v3.1 (#234)

### v3.1.x specifics

- Minimum PVE: 9.x
- `api()` bumped to match PVE 9's `APIVER` at time of release
- `volume_snapshot*` implementation (#234)
- Evaluate removal of `qemu_blockdev_options` override if Proxmox has fixed upstream
- `api()` bump tracked in #270

## Consequences

- v3.0.0 can be tagged — PVE 8 + PVE 9 both verified
- v3.1.0 milestone must add `api()` bump (#270) as a prerequisite
- ROADMAP updated: v3.2.0 renamed to v4.0.0 for WebSocket API (#243)
- ADR-008 marked Superseded when this ADR is accepted

## Alternatives Considered

**v4.0 for dropping PVE 8**: Rejected — dropping an EOL platform is not a
behavioral break. Users on PVE 8 keep using v3.0.x. A major version would
signal something fundamentally different about what the plugin does.

**v3.x for WebSocket API**: Rejected — WebSocket JSON-RPC 2.0 changes the
transport layer and may require dropping or splitting REST API support. That is
an architectural change deserving a major version signal to users.
