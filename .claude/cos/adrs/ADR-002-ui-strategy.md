# ADR-002: UI Integration Strategy

**Date**: 2026-05-15  
**Status**: Under Discussion  
**Deciders**: Kevin Adams

## Context

The plugin currently adds a UI by patching `pvemanagerlib.js`, the monolithic JavaScript bundle that is Proxmox VE's entire web UI. A separate versioned patch file must be maintained for each Proxmox VE minor release. When PVE updates, the patch breaks.

The desired end state is a UI that:
- Doesn't break on every PVE update
- Ideally doesn't require patching PVE system files
- Shows appropriate fields for TrueNAS API credentials

## Options Evaluated

### Option A — Continue Patching pvemanagerlib.js (Status Quo)

The current approach. Diff the upstream PVE JS, produce a patch per PVE version.

- **Pro**: Works in all PVE versions, field placement is ideal
- **Con**: Breaks on every PVE minor release; versioned patch sprawl is visible in the repo already (stable-5 through stable-8 folders)
- **Verdict**: Manageable with better automation (auto-detect PVE version in postinst and select the right patch)

### Option B — Serve a Separate JS File via pveproxy

Proxmox VE's `pveproxy` serves everything from `/usr/share/pve-manager/`. The HTML template (`/usr/share/pve-manager/index.html.tpl`) explicitly lists which JS files to load. A new file could be injected either by:
(a) Patching `index.html.tpl` to add a `<script>` tag — still a patch
(b) Discovering if pveproxy supports a "extras" JS directory — not documented, needs investigation

If pveproxy or its Perl handler exposes a hook point, a standalone `truenas-plugin.js` could be dropped in without touching pvemanagerlib.js. The JS would use `Ext.override()` to modify existing components.

- **Pro**: Single JS file, not tied to PVE version; installs cleanly
- **Con**: `Ext.override` is fragile when component internals change; still requires some PVE integration point
- **Verdict**: Worth investigating for PVE 8.x

### Option C — Full Custom Storage Plugin (`PVE::Storage::Custom`)

Register a brand-new storage type (e.g., `truenas`) rather than wedging into `ZFS-over-iSCSI`. Proxmox VE discovers `PVE::Storage::Custom::*` plugins at runtime via `Module::Load`. The UI in PVE 8.x automatically generates a form panel from the plugin's `properties()` definition.

The file `perl5/PVE/Storage/Custom/FreeNAS.pm` is an unfinished attempt at this. It registers `package PVE::Storage::Custom::TrueNASPlugin` with `type => 'truenas'`.

- **Pro**: No JS patching needed; plugin-managed UI; proper separation
- **Con**: Requires implementing the full `PVE::Storage::Plugin` API (alloc_image, free_image, list_images, status, etc.) which is significantly more work. Also, ZFS pool listing still uses SSH via `ZFSPoolPlugin.pm` which is outside our scope.
- **Verdict**: Best long-term architecture, but highest implementation effort. The existing `Custom/FreeNAS.pm` gives a starting point.

### Option D — Hybrid: Fix Patch Automation Now, Plan for Option C Later

1. **Now**: Fix postinst to select the correct patch for the installed PVE version automatically (no more per-version patch files in the repo — derive them at build time or select at install time)
2. **Later**: Complete `PVE::Storage::Custom::TrueNASPlugin` as a proper plugin when bandwidth allows

## Decision

**Decided 2026-05-15**: Option C — Full `PVE::Storage::Custom` Plugin (v3.x target)

Kevin confirmed this is the goal. The existing `perl5/PVE/Storage/Custom/FreeNAS.pm` is the starting point; it needs the duplicate subs fixed and the full `PVE::Storage::Plugin` interface implemented.

**Benefits realized**:
- Zero JS patching — PVE auto-generates UI from `properties()`
- Zero `ZFSPlugin.pm` patching — new type, not wedged into existing
- Zero `apidoc.js` patching — auto-documented
- Can eliminate SSH requirement — pool stats via TrueNAS API v2.0
- `postinst` becomes trivial: just copy two `.pm` files, restart services

**What the Custom plugin still needs `iscsiadm` for** (unavoidable, runs on Proxmox host):
- iSCSI login/logout (`activate_volume` / `deactivate_volume`)
- Device discovery after login (`/dev/disk/by-path/` or multipath)

**Migration path from v2.x → v3.x**:
- v2.x packages remain installable (they keep the ZFSPlugin.pm patch approach)
- v3.x introduces `type => 'truenas'` storage; users create a new storage and migrate VMs
- v3.x `postinst` can detect old `freenas`-provider storages and warn the user

## Open Questions Resolved

- PVE 8.x `Custom::` plugins DO auto-generate UI forms from `properties()`
- Kevin has a lab PVE 8.x node available for testing

