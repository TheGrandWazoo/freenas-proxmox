# Research Brief: PVE 8.4 / 9.0 / 9.1 Release Notes — Plugin Impact

**Date**: 2026-05-19  
**Author**: Kevin Adams (research via Claude Code)  
**Status**: Final — findings incorporated into ADR-008 and open issues

---

## Summary

Reviewed Proxmox VE release notes for 8.4, 9.0, and 9.1 to identify changes that
affect the freenas-proxmox plugin (v2.x) and inform Phase 3 (v3.0) design.

---

## PVE 8.4

**Package versions**: Kernel 6.8

### Relevant findings

| Area | Change | Impact |
|------|--------|--------|
| iSCSI | Initial support for portals returning **hostnames instead of IPs** | Our plugin assumes IP addresses; DNS names will fail |
| pvemanagerlib.js | Something changed that breaks our existing patch | Issue #223 — blocked on getting JS from lab node |

### Known issues (from PVE 8.4)
- PXE boot on VM with OVMF requires VirtIO RNG
- Broken iGPU pass-through in legacy mode
- OSDs deployed on Ceph Squid crash (unrelated)
- Download-from-URL now uses proxy for HTTPS — may affect postinst if proxy is set

---

## PVE 9.0

**Package versions**: QEMU 10.0.2, LXC 6.0.4, ZFS 2.3.3, Ceph Squid 19.2.3, Kernel 6.14.8

### Relevant findings

| Area | Change | Impact |
|------|--------|--------|
| iSCSI | Hostname portal support (confirmed) | Same gap as 8.4 — DNS name handling needed |
| **Snapshot-as-Volume-Chains** (Tech Preview) | Thick-provisioned iSCSI/FC LUNs now support snapshots via volume chains | **Phase 3 opportunity**: if we implement the proper PVE storage plugin interface, TrueNAS ZFS snapshots map directly to this |
| LVM | Autoactivation disabled for new LVs — migration script provided | Watch for interaction with how PVE activates our iSCSI LUNs |
| GlusterFS | Dropped entirely | Signals Proxmox will remove unmaintained plugins — we need a real maintenance path |
| ZFS 2.3.3 | RAIDZ pool expansion without downtime | Informational — no plugin impact |

### Phase 3 note
The Snapshot-as-Volume-Chains feature in PVE 9.0 is the strongest argument for
implementing the full `PVE::Storage::Custom` interface in v3.0. Snapshot support
requires proper `volume_snapshot`, `volume_snapshot_rollback`, and
`volume_snapshot_delete` method implementations. TrueNAS ZFS snapshots map to
these naturally via the TrueNAS API.

---

## PVE 9.1

**Package versions**: QEMU 10.1.2, LXC 6.0.5, ZFS 2.3.4, Ceph Squid 19.2.3, Kernel 6.17.2

### Relevant findings

| Area | Change | Impact |
|------|--------|--------|
| Volume chain snapshots | Bug fix: snapshot would fail after a disk move | Phase 3 snapshot implementation should test this scenario |
| LVM-thick | Switches from `cstream` to `blkdiscard` for wiping removed volumes | Watch for interaction with LUN deletion path |
| iSCSI | Hostname portal support (carried forward from 9.0) | Still a gap |
| Mobile UI | OIDC realm login, VM option editing | No plugin impact |

---

## Decisions Triggered

| Decision | Where documented |
|----------|-----------------|
| PVE version support matrix for v2.x and v3.0 | ADR-008 |
| DNS/hostname support for iSCSI portal connections | GitHub issue #232+ |
| Phase 3 snapshot interface requirement | GitHub issue — see Epic #219 |

---

## Action Items Created

| Issue | Title | Milestone |
|-------|-------|-----------|
| [#233](https://github.com/TheGrandWazoo/freenas-proxmox/issues/233) | Feature: Add DNS/hostname support for iSCSI portal connections | v2.3.0 |
| [#234](https://github.com/TheGrandWazoo/freenas-proxmox/issues/234) | Feature: Phase 3 — implement snapshot interface (Snapshot-as-Volume-Chains) | v3.0.0 |
| ADR-008 | PVE Version Support Matrix | n/a |
