# ADR-011: APT Components for Optional Feature Packages

**Date**: 2026-06-06
**Status**: Accepted
**Deciders**: Kevin Adams

## Context

ADR-010 established per-major-version dist tracks (`main`, `v2`, `v3`, `v4`) on the
GitHub Pages apt repo. That decision covers *which version* a user receives. It does
not address *which features* within a version they receive.

The multipath plugin (#256) is the first optional feature that should not be installed
by default. Bundling it into the `truenas-proxmox` package would force all users to
carry `iscsiadm` dependencies and a `TrueNASMultipath.pm` code path they never use.
A separate package (`truenas-proxmox-multipath`) is the right model, but it needs a
distribution mechanism that:

- Does not require users to add a second, unrelated repo URL
- Does not appear in `apt upgrade` for users who never opted in
- Scales to future optional features (TPM workarounds, per-vendor drivers, etc.)

## Decision

Use **apt components** to distribute optional feature packages within the existing
dist tracks.

### Structure

```
dists/v3/
  Release              ← Components: main multipath
  main/
    binary-all/
      Packages         ← truenas-proxmox, freenas-proxmox (transitional)
  multipath/
    binary-all/
      Packages         ← truenas-proxmox-multipath
```

### Sources.list lines

```
# Standard install — only main component, no optional packages
deb [signed-by=/etc/apt/keyrings/truenas-proxmox.gpg] \
  https://thegrandwazoo.github.io/freenas-proxmox v3 main

# With multipath support
deb [signed-by=/etc/apt/keyrings/truenas-proxmox.gpg] \
  https://thegrandwazoo.github.io/freenas-proxmox v3 main multipath
```

Users who do not add `multipath` to their sources line never see
`truenas-proxmox-multipath` as a candidate — `apt upgrade` will not install it.

### Component naming convention

| Component | Contents | Who uses it |
|-----------|----------|-------------|
| `main` | Base plugin (`truenas-proxmox`) | All installs |
| `multipath` | `truenas-proxmox-multipath` | Users with multipath hardware |

Future components follow the same pattern: one component per optional feature,
named for the feature not the package.

### CI publishing

The build workflow generates a `Packages.gz` per component. Optional-feature packages
are built from subdirectories or separate workflow files and published into their
component directory. The `Release` file is regenerated after all components are
populated, listing all available components in the `Components:` field.

### Testing track

When the GitHub Pages testing track ships (#272), optional components exist there too:

```
dists/testing/
  Release              ← Components: main multipath
  main/binary-all/Packages
  multipath/binary-all/Packages
```

Beta users opt into beta multipath builds via `testing main multipath`.

## Consequences

- Users have a single repo URL for all packages from this project, regardless of
  which features they use
- `apt upgrade` respects user intent: standard users never receive optional packages
- Adding a new optional feature is a new component — no changes to existing packages
  or `main` component machinery
- The `Release` file must list all components; CI must regenerate it when any
  component's content changes
- `truenas-proxmox-multipath` has a `Depends: truenas-proxmox` so apt enforces
  install order and prevents the optional package from being installed alone

## Alternatives Considered

**Option A — Separate repo URL per optional feature** (e.g., a second GitHub Pages
site or Cloudsmith repo): Requires users to manage multiple repo entries and GPG keys.
Rejected — adds friction for users and management overhead.

**Option B — Bundle everything in `main`** with optional code gated by config flags:
Forces all users to carry dependencies they may never use; makes the base package
harder to audit. Rejected — this is what the v2.x `ZFSPlugin.pm` patch model did.

**Option C — GitHub Packages / OCI**: Does not support raw apt repos. Not viable.

## References

- ADR-010: per-major-version apt dist tracks (established the repo structure this extends)
- Issue #256: multipath plugin (first consumer of a non-`main` component)
- Issue #272: GitHub Pages testing track (testing component support needed here too)
