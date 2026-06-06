# Upgrade Paths

Quick reference for every migration scenario. Find your current version and repo source in the table, then follow the link for step-by-step instructions.

---

## Where am I, and where do I go?

| Current version | Current repo | → Stay on current major | → Move to v3.x | → Move to v4.x |
|---|---|---|---|---|
| **v2.x** | Cloudsmith stable | [Swap repo to GitHub Pages `main`](#cloudsmith-to-github-pages) | [Swap repo + config migration](migrating-from-v2.md) | TBD when v4 ships — will require v3 config first |
| **v2.x** | GitHub Pages `main` | Already on correct repo ✅ | [Config migration only](migrating-from-v2.md) | TBD when v4 ships — will require v3 config first |
| **v3.x** | Cloudsmith stable | [Swap repo to GitHub Pages `v3`](#cloudsmith-to-github-pages) | Already on v3 — swap repo only | [Change dist track to `v4` + v3→v4 guide](#future-v4) |
| **v3.x** | GitHub Pages `v3` | Already on correct repo ✅ | Already here ✅ | [Change dist track to `v4` + v3→v4 guide](#future-v4) |

**Not sure which version you have?** Run this on any Proxmox node:
```bash
dpkg -l truenas-proxmox freenas-proxmox 2>/dev/null | grep '^ii'
```

**Not sure which repo you're using?**
```bash
cat /etc/apt/sources.list.d/truenas-proxmox*.list /etc/apt/sources.list.d/freenas-proxmox*.list 2>/dev/null
```

---

## Cloudsmith → GitHub Pages {#cloudsmith-to-github-pages}

> Cloudsmith is being phased out. GitHub Pages is the permanent home for this project's packages. Your installed package is not affected — this only changes where future updates come from.

Full instructions are in the [README — Migrating from Cloudsmith](../README.md#migrating-from-cloudsmith) section.

In short:
1. Remove your existing Cloudsmith source file from `/etc/apt/sources.list.d/`
2. Remove the old Cloudsmith keyring from `/usr/share/keyrings/`
3. Import the GitHub Pages GPG key to `/etc/apt/keyrings/truenas-proxmox.gpg`
4. Add the GitHub Pages source pointing at the right dist track (`main` for v2, `v3` for v3)
5. Run `apt update`

---

## What changes between major versions

| | v2.x → v3.x | v3.x → v4.x (future) |
|---|---|---|
| **Breaking change?** | Yes — auth model, iSCSI model, package name | Yes — WebSocket API replaces REST |
| **In-place upgrade?** | No — VM disks must be moved | TBD |
| **Plugin restarts VMs?** | No — Move Disk is live | TBD |
| **Config changes?** | Yes — API key replaces username/password | TBD |
| **Full guide** | [migrating-from-v2.md](migrating-from-v2.md) | Will be added when v4 ships |

---

## v2.x → v3.x

See [migrating-from-v2.md](migrating-from-v2.md) for the full step-by-step guide.

High-level steps:
1. Install `truenas-proxmox` on every Proxmox node (from GitHub Pages `v3` dist)
2. Create a TrueNAS API key
3. Add a new v3 storage entry in Proxmox (keep the old v2 entry running alongside)
4. Move VM disks one at a time using Proxmox Move Disk (VMs stay running)
5. Remove the old v2 storage entry once all disks are moved

**Do not run `apt upgrade` from a v2 Cloudsmith install without reading the migration guide first.** v3.0 is a breaking change — your storage will need reconfiguration.

---

## v3.x → v4.x (future) {#future-v4}

v4.0 will replace the TrueNAS REST API with the WebSocket JSON-RPC 2.0 API introduced in TrueNAS SCALE 25.04. This is an architectural change and will be a major version with its own migration guide.

When v4.0 ships, this section will be updated with:
- What changes in v4.0 (API model, config fields, compatibility matrix)
- Whether an in-place upgrade is possible
- Step-by-step migration from v3.x
- Step-by-step migration from v2.x (if a direct v2→v4 path is supported)

**To receive v4.x packages when they ship**, you will need to change your `sources.list` dist track from `v3` to `v4`:

```bash
# When v4.0 is released — do NOT run this until the v4 migration guide is published
echo "deb [signed-by=/etc/apt/keyrings/truenas-proxmox.gpg] \
https://thegrandwazoo.github.io/freenas-proxmox v4 main" \
  | sudo tee /etc/apt/sources.list.d/truenas-proxmox.list
sudo apt update
```

`apt upgrade` on the `v3` dist track will never pull in a v4 package — you must explicitly change the dist track. This is intentional.

---

## Dist track reference

| Dist track | Contains | Who should use it |
|---|---|---|
| `main` | v2.x packages only | Users staying on v2.x |
| `v2` | v2.x packages (alias for `main`) | Same as `main` — explicit pin |
| `v3` | v3.x packages only | All current v3 installs |
| `v4` | v4.x packages only | Added when v4.0 ships |

Packages on one dist track are never promoted to another. Changing major versions always requires an explicit `sources.list` edit.
