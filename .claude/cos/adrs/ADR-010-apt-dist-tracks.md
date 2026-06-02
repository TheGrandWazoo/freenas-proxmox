# ADR-010: APT Repository Dist Tracks — Per-Major-Version Isolation

**Date**: 2026-06-02  
**Status**: Accepted  
**Deciders**: Kevin Adams  
**Supersedes**: ADR-003

## Context

Issue #271 exposed a gap: a user running v2.4.0 with the stable Cloudsmith repo ran
`apt upgrade` and was silently promoted to v3.0.0 — a rewrite with breaking auth and
iSCSI model changes. The user had no warning, no release notes were published at the
time, and their host broke.

The root cause is that a single dist (`main`) serves all major versions. `apt upgrade`
has no way to know that crossing a major version boundary requires deliberate action.
Debian solves this with release codenames (`bookworm`, `trixie`): users choose a
release track explicitly and are never silently promoted across breaking boundaries.

ADR-003 established GitHub Pages as the target apt repo infrastructure and specified
a single `dists/stable/` dist. That structure does not support per-major-version
isolation. This ADR supersedes ADR-003 in full — the GitHub Pages hosting decision
is retained, but the dist layout, CI publishing rules, and Cloudsmith transition
plan replace what ADR-003 specified.

## Decision

### Dist track structure

| Dist | Content | Who uses it |
|------|---------|-------------|
| `main` | v2.x packages only | Existing users — backward-compatible; no change to their `sources.list` |
| `v2` | v2.x packages (alias for `main`) | Users who want to explicitly pin to v2 |
| `v3` | v3.x packages only | Users upgrading to v3, and all new installs |

`main` and `v2` serve identical package content. `main` exists purely for backward
compatibility with users who already have it in their `sources.list`. `v2` is the
explicit alias for those who add it knowingly.

When v4.0 ships, a `v4` dist is added. `v3` continues to receive v3.x point releases.
No existing user is auto-promoted.

### Directory layout (GitHub Pages apt repo)

```
dists/
  main/                    ← v2.x — backward-compat alias
    Release
    InRelease              (GPG signed)
    main/binary-all/
      Packages
      Packages.gz
  v2/                      ← v2.x — explicit alias (identical content to main/)
    Release
    InRelease
    main/binary-all/
      Packages
      Packages.gz
  v3/                      ← v3.x only
    Release
    InRelease
    main/binary-all/
      Packages
      Packages.gz
pool/
  main/                    ← shared pool — all .deb files for all versions
    truenas-proxmox_2.*.deb
    truenas-proxmox_3.*.deb
    ...
```

`main/` and `v2/` reference the same pool entries. CI generates both `Packages.gz`
files from the same v2.x package list — no filesystem symlinks needed.

### Sources.list lines users will have

```
# Existing users (v2.x, unchanged):
deb [signed-by=/etc/apt/keyrings/truenas-proxmox.gpg] https://thegrandwazoo.github.io/freenas-proxmox main main

# Explicit v2 pin (same content):
deb [signed-by=/etc/apt/keyrings/truenas-proxmox.gpg] https://thegrandwazoo.github.io/freenas-proxmox v2 main

# v3.x installs:
deb [signed-by=/etc/apt/keyrings/truenas-proxmox.gpg] https://thegrandwazoo.github.io/freenas-proxmox v3 main
```

### CI behavior

The build workflow publishes each `.deb` to the pool unconditionally, then regenerates
only the `Packages.gz` files for the dists that cover that major version:

- v2.x tag (`v2.*.*`) → regenerate `main/` and `v2/` dists
- v3.x tag (`v3.*.*`) → regenerate `v3/` dist only
- v4.x tag (`v4.*.*`) → regenerate `v4/` dist only (created when needed)

`main/` is never updated by a v3+ build. This is the enforcement mechanism.

### Cloudsmith transition

Cloudsmith will continue to serve packages in parallel during the GitHub Pages rollout
(per ADR-003). When the GitHub Pages repo is live and announced:

- New installs → GitHub Pages, `v3 main`
- Existing Cloudsmith users → stay on Cloudsmith until they choose to migrate
- Cloudsmith is not updated with per-version dists — it remains a transitional channel

Cloudsmith is dropped after v3.x is the stable generation and Cloudsmith user traffic
has subsided (tracked under issue #230).

## Consequences

- Users on `main` never receive a v3+ package unless they change their `sources.list`.
  The v2.x → v3.0 silent-upgrade incident (#271) cannot recur for future major versions.
- New users must explicitly choose a dist track. The README and getting-started docs
  must make `v3 main` the default for new installs.
- The CI build workflow (issue #230) must be updated to maintain multiple `Packages.gz`
  files, keyed by the major version of the package being published.
- This structure is gated on #230 (GitHub Pages apt repo). Cloudsmith does not support
  per-dist isolation within a single repo without additional paid repos.

## Alternatives Considered

**Option B — Separate Cloudsmith repo per major version** (`truenas-proxmox-v2`,
`truenas-proxmox-v3`): Works today without #230. Rejected because it requires users
to change their repo URL on every major version, and Cloudsmith repo sprawl adds cost
and management overhead. GitHub Pages dist tracks are cleaner long-term.

**Option C — Debian package epochs** (`1:2.4.0-1`, `2:3.0.0-1`): Epochs prevent
`apt upgrade` from crossing the boundary, but they are opaque to users, poorly
documented in the ecosystem, and do not solve the "wrong content in the right repo"
problem. Rejected as an internal hack with poor user-facing semantics.

## References

- Issue #271 — silent v2→v3 upgrade incident (motivation)
- Issue #230 — GitHub Pages apt repo (implementation prerequisite)
- ADR-003 — apt repo hosting decision (GitHub Pages approach retained; dist structure superseded)
- ADR-006 — versioning strategy (major/minor/patch semantics)
