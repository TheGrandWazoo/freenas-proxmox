# ADR-008: PVE Version Support Matrix

**Date**: 2026-05-19  
**Status**: Accepted  
**Deciders**: Kevin Adams

## Context

Proxmox VE releases 8.4, 9.0, and 9.1 introduced storage-subsystem changes that
affect which PVE versions the plugin must support and under what constraints.
Specifically:

- **PVE 8.4** broke our existing `pvemanagerlib.js` patch (issue #223)
- **PVE 9.0** introduced Snapshot-as-Volume-Chains for thick-provisioned iSCSI
- **PVE 9.1** is the current stable release as of 2026-05-19

The plugin currently ships a single patch per major PVE version (7.x, 8.x).
Phase 3 (v3.0) eliminates all patches by using the proper `PVE::Storage::Custom`
plugin interface — but we need a clear decision on which PVE versions each release
series must support.

## Decision

### v2.x (current) — patch-based

| PVE version | Support level | Notes |
|-------------|--------------|-------|
| PVE 7.x | Best-effort | No active testing; patches ship but may lag |
| PVE 8.0–8.3 | Supported | Existing patch works |
| PVE 8.4.x | Supported (blocked) | pvemanagerlib.js patch broken — fix tracked in #223 |
| PVE 9.x | Not supported | pvemanagerlib.js too diverged; v3.0 is the answer |

v2.3.0 is the **last planned release to ship patched versions of PVE system files**.
It will support PVE 7 (best-effort) and PVE 8 (fully). PVE 9.x users should wait
for v3.0 or run v2.x in degraded mode (plugin works; UI dropdown may not show).

### v3.0.x — custom plugin, no patches

| PVE version | Support level | Notes |
|-------------|--------------|-------|
| PVE 8.x | Supported (core) | Custom plugin interface available since PVE 7 |
| PVE 9.0+ | Fully supported | Includes snapshot-as-volume-chains integration |
| PVE 7.x | Not supported | v3.0 requires API features not available in PVE 7 |

**Minimum supported PVE for v3.0: 8.x (core), 9.0 (snapshots).**

Snapshot support (`volume_snapshot`, `volume_snapshot_rollback`,
`volume_snapshot_delete`) requires PVE 9.0 Snapshot-as-Volume-Chains and will
be gated at runtime: the methods will be present but return an appropriate error
on PVE < 9.0.

## Consequences

- Issue #223 (pvemanagerlib.js PVE 8.4 fix) must ship in v2.3.0
- v3.0.0 must implement the full `PVE::Storage::Custom` interface including
  `volume_snapshot*` methods (initially returning unsupported on PVE < 9.0)
- CI for v3.0 must test against both PVE 8.x and PVE 9.x targets
- The v3.0.0 milestone description and related issues should call out
  PVE 9.0 as the target for snapshot feature parity
- PVE 9.x users stuck on v2.x should be documented in a known-limitations note

## Alternatives Considered

**Support PVE 9.x in v2.x via a new patch**: rejected — pvemanagerlib.js diverged
significantly in 9.0; maintaining a third patch variant adds fragility without
addressing the root cause (patch-based approach).

**Make PVE 9.0 the minimum for v3.0**: rejected — custom storage plugins work in
PVE 8.x and dropping 8.x support would leave a large user base with no upgrade
path until they upgrade PVE.
