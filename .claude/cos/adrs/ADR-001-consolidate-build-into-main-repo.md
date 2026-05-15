# ADR-001: Consolidate Build Pipeline into Main Repo

**Date**: 2026-05-15  
**Status**: Proposed  
**Deciders**: Kevin Adams

## Context

The build pipeline is split across two GitHub repos:
- `freenas-proxmox` — source code + patches
- `freenas-proxmox-packer` — DEBIAN packaging structure + CI that actually builds the `.deb`

Communication is via `repository_dispatch` which requires a stored `ACCESS_TOKEN` secret. This creates maintenance overhead (two repos to keep in sync, two sets of CI secrets, cross-repo dependencies) and confusion about where things live.

Additionally, the current `postinst` script **git-clones this repo at install time**, which requires internet access on the Proxmox node and is fragile.

## Decision

Move all packaging (DEBIAN structure, CI workflow) into the main `freenas-proxmox` repo. The `.deb` package will embed all required files during the build step, not at install time.

## Consequences

**Positive**:
- Single repo to maintain
- No cross-repo dispatch tokens needed
- Package installs offline (no git at install time)
- Simpler CI secrets (only Cloudsmith API key needed)
- Easier to test packaging changes alongside code changes

**Negative**:
- The `freenas-proxmox-packer` repo becomes deprecated (should be archived, not deleted — it has history)
- Need to restructure CI branch logic (currently done in the packer repo's action)

## Implementation Notes

Proposed directory layout in main repo:
```
packaging/
├── DEBIAN/
│   ├── control.j2      # Jinja2/envsubst template for version injection
│   ├── postinst
│   ├── postrm
│   └── triggers
└── files/              # Files to be embedded in the package (no git clone at install)
    └── (populated by CI from the source tree)
```

The CI workflow should:
1. Check out the repo
2. Detect branch/tag to set version + repo component (dev/testing/stable)
3. Run `envsubst` on `control.j2` to inject version
4. Copy source files into the package staging area
5. Run `dpkg-deb --build`
6. Push to Cloudsmith (and optionally GitHub Releases)
