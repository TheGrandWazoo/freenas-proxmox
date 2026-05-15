# freenas-proxmox — Claude Code Guide

## What This Project Is

A storage plugin "wedge" for Proxmox VE (PVE) that allows PVE to manage iSCSI LUNs on TrueNAS/FreeNAS via the TrueNAS REST API instead of the traditional SSH-based `iscsiadm` approach.

The plugin installs as a Debian package and works by:
1. Deploying a new Perl LunCmd handler (`FreeNAS.pm`) to `/usr/share/perl5/PVE/Storage/LunCmd/`
2. Patching three Proxmox VE system files at install time via `dpkg triggers`

## Repository Layout

```
freenas-proxmox/
├── perl5/PVE/Storage/
│   ├── Custom/FreeNAS.pm          # Old attempt at a full custom storage type (unfinished)
│   ├── LunCmd/FreeNAS.pm          # MAIN backend: iSCSI LunCmd via TrueNAS REST API
│   ├── LunCmd/FreeNAS-ng.pm       # Next-gen draft (not in use)
│   └── ZFSPlugin-*.pm.patch       # Per-PVE-version patches for ZFSPlugin.pm
├── pve-manager/js/
│   └── pvemanagerlib-*.js.patch   # Per-PVE-version patches for the Proxmox UI JS
├── pve-docs/api-viewer/
│   └── apidoc-*.js.patch          # Per-PVE-version patches for the API docs JS
├── perl5/REST/Client.pm           # Bundled REST::Client (also an apt dependency)
├── stable-5/, stable-6/, stable-7/, stable-8/
│                                  # Per-major-version snapshots of patches + originals
└── .github/workflows/action.yml   # Currently just dispatches to external packer repo
```

## How the Current Build Works (Two-Repo Problem)

1. A push to this repo triggers `action.yml` which fires a `repository_dispatch` event to `TheGrandWazoo/freenas-proxmox-packer`
2. That separate repo holds the DEBIAN package structure (`DEBIAN/control`, `postinst`, `postrm`, `triggers`)
3. Its CI builds the `.deb` with `dpkg-deb` and pushes to Cloudsmith

The `postinst` script at install time **git-clones this repo** to `/usr/local/src/freenas-proxmox` and applies patches from there. This is the key fragility — internet access required at package install time.

## Three Files That Get Patched at Install Time

| File | What the patch adds |
|------|---------------------|
| `/usr/share/perl5/PVE/Storage/ZFSPlugin.pm` | Adds `freenas` as a valid iSCSI provider, routes `run_lun_command` to `FreeNAS.pm`, adds custom properties/options |
| `/usr/share/pve-manager/js/pvemanagerlib.js` | Adds `FreeNAS/TrueNAS API` to the iSCSI provider dropdown; adds UI fields for API host, user, secret, SSL, token auth |
| `/usr/share/pve-docs/api-viewer/apidoc.js` | Registers TrueNAS-specific properties in the API docs |

## Authentication Modes Supported

- **Basic Auth**: `freenas_user` + `freenas_password` (deprecated but still works)
- **Bearer Token**: `truenas_token_auth=true` + `truenas_secret` (preferred for TrueNAS SCALE)

## TrueNAS API Version Detection

The plugin auto-detects v1.0 vs v2.0 API based on the TrueNAS version string and HTTP response:
- `>= 11.03.01.00` → uses v2.0 API
- Older → uses v1.0 API

## Known Issues / Active Work

- Versioned patches are fragile — each PVE minor release may need a new patch
- `postinst` clones the repo at install time (requires internet, fragile)
- `Custom/FreeNAS.pm` is unfinished (duplicate `properties()` and `options()` subs)
- REST::Client is both an apt dependency AND manually bundled
- Everything is named `FreeNAS` internally but the product is now `TrueNAS`
- SSH keys still required for ZFS pool listing (separate Proxmox code path via `ZFSPoolPlugin.pm`)
- Max LUN limit bug (#150)

## Key Perl Modules

- `PVE::Storage::LunCmd::FreeNAS` — the main plugin. Entry point: `run_lun_command()`
- Functions: `freenas_api_connect`, `freenas_api_check`, `freenas_api_call`, `freenas_list_lu`, `run_create_lu`, `run_delete_lu`, `run_modify_lu`

## Packaging / Deployment Notes

- Package name: `freenas-proxmox`
- Apt repos: Cloudsmith (`ksatechnologies/truenas-proxmox` stable, `ksatechnologies/truenas-proxmox-testing` beta)
- Install: `apt install freenas-proxmox` after adding the repo
- The package uses dpkg `triggers` to re-apply patches when Proxmox VE packages are upgraded

## ADRs / Plans / Runbooks

See `.claude/cos/adrs/` for Architecture Decision Records.
See `.claude/cos/plans/` for implementation plans.
See `.claude/cos/runbooks/` for operational runbooks.
