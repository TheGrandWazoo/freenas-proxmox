# ADR-006: Package Versioning Strategy

**Date**: 2026-05-15  
**Status**: Decided  
**Deciders**: Kevin Adams

## Context

The package has historically had version strings tied to specific Proxmox or TrueNAS releases (e.g., `ZFSPlugin-8.0.5_1.pm.patch`, `pvemanagerlib-7.4-3_1.js.patch`). This creates confusion — users aren't sure if `2.2.0-1` means it works with TrueNAS 2.2 or Proxmox 2.2.

## Decision

The package version is **independent** of both Proxmox VE and TrueNAS versions.

- Package version: semantic versioning `MAJOR.MINOR.PATCH` (e.g., `3.0.0`, `3.1.2`)
- Supported Proxmox VE versions and TrueNAS versions are documented in:
  - GitHub Release notes (the primary place — visible when users click on a release)
  - The `Description` field in `DEBIAN/control`
  - README.md compatibility table

## Version Scheme

| Series | Meaning |
|--------|---------|
| `2.x.x` | Current approach (ZFSPlugin.pm patch wedge) |
| `3.x.x` | New `TrueNASPlugin` custom storage type |
| `3.0.x` | Patch releases for 3.0 (bug fixes, no new features) |
| `3.1.x` | Next minor — could add features like snapshot support |

## GitHub Release Notes Template

Each release on GitHub should include:

```markdown
## freenas-proxmox v3.0.0

### Supported Proxmox VE Versions
- Proxmox VE 8.0, 8.1, 8.2, 8.3

### Supported TrueNAS Versions  
- TrueNAS CORE 13.0-U6+
- TrueNAS SCALE 23.10+, 24.04+

### What's New
- ...

### Breaking Changes from v2.x
- Storage type changes from `ZFS over iSCSI (freenas provider)` to `TrueNAS (API)`
- Migration guide: [link]
```

## CI Version Injection

The version is set in one place: a `VERSION` file or git tag at the repo root. CI reads it and injects via `envsubst` into `packaging/DEBIAN/control.j2`.

Branch-to-channel mapping (not version mapping):
- `feature_*` → alpha channel  
- `master` → beta/testing channel  
- Tagged release (`v3.0.0`) → stable channel
