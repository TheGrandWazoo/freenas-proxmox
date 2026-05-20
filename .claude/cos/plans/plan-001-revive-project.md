# Plan 001: Project Revival — Overall Roadmap

**Date**: 2026-05-15  
**Status**: Approved — ready for implementation  
**Owner**: Kevin Adams

## Decisions Made

| Topic | Decision |
|-------|----------|
| Build pipeline | Consolidate into this repo; eliminate packer repo dispatch |
| Install-time deps | No git, diff, or patch at install time — embed all files in .deb |
| apt hosting | Transition to GitHub Pages (parallel with Cloudsmith, then cut over) |
| UI strategy | Full `PVE::Storage::Custom::TrueNASPlugin` + standalone JS file |
| JS patching | Single minimal patch to `index.html.tpl` to load `truenas-plugin.js` |
| Auth | Bearer Token as primary; basic auth as fallback for compat |
| Cleanup on failure | Rollback dangling TrueNAS resources on any step failure (ADR-004) |
| Code hardening | All findings in plan-002-code-review.md to be addressed |

---

## Architecture After v3.x

### What Gets Installed

```
/usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm   ← new custom storage plugin
/usr/share/perl5/PVE/Storage/LunCmd/TrueNAS.pm          ← API client (renamed + hardened)
/usr/share/pve-manager/js/truenas-plugin.js             ← standalone UI JS (NO pvemanagerlib patch)
```

### What Gets Patched (minimal, stable)

```
/usr/share/pve-manager/index.html.tpl                   ← ONE LINE: add <script> for truenas-plugin.js
```

That's it. No `ZFSPlugin.pm` patch. No `pvemanagerlib.js` patch. No `apidoc.js` patch. The `index.html.tpl` is orders of magnitude more stable than the JS bundle.

### How `truenas-plugin.js` Works

Ships a proper `Ext.define('PVE.storage.TrueNASInputPanel', {...})` that registers as the configuration panel for `type = 'truenas'` storage. The panel handles:
- API host field
- Toggle: Bearer Token vs Username/Password
- Conditional field visibility (hide username when token auth is selected)
- Secret/token field with confirm
- SSL checkbox
- Pool field

When PVE renders the storage configuration dialog and sees `type = 'truenas'`, it picks up our registered panel class.

### `postinst` — What It Does

```bash
1. cp /usr/share/truenas-proxmox/TrueNASPlugin.pm    /usr/share/perl5/PVE/Storage/Custom/
2. cp /usr/share/truenas-proxmox/TrueNAS.pm           /usr/share/perl5/PVE/Storage/LunCmd/
3. cp /usr/share/truenas-proxmox/truenas-plugin.js    /usr/share/pve-manager/js/
4. patch /usr/share/pve-manager/index.html.tpl        (one <script> line, idempotent check first)
5. pvedaemon restart && pveproxy restart && pvestatd restart
```

No git. No curl. No version-matrix. No patch selection logic.

---

## Implementation Phases

### Phase 0 — Lab Environment Setup
**Owner**: Kevin  
**What**: Build a PVE 8.x node in the lab for testing  
**Needed before**: Phase 2

### Phase 1 — Build Pipeline (no source changes)

**Goal**: CI/CD lives entirely in this repo; .deb builds and deploys from here

Tasks:
- [ ] Create `packaging/DEBIAN/` directory with `control`, `postinst`, `postrm`, `triggers`
- [ ] Port existing packaging from packer repo (keeping the v2.x approach for now)
- [ ] Rewrite `postinst` to not git-clone at install (embed files at build time)
- [ ] Create `.github/workflows/build.yml` replacing `action.yml`
  - Branch → version + component mapping (feature_ → alpha, master → beta, 2.0 → stable)
  - `dpkg-deb` build step
  - Cloudsmith push (existing key)
  - GitHub Release asset upload
- [ ] Set up GitHub Pages apt repo structure in `docs/` branch or `gh-pages` branch
  - `apt-ftparchive` to generate Packages/Release files
  - GPG signing step (new key, stored as GH secret)
- [ ] Archive packer repo (do NOT delete — it has release history)

**Result**: Same v2.x packages but built entirely from this repo with no git at install.

### Phase 2 — Code Hardening (FreeNAS.pm / current approach)

**Goal**: Fix all critical and high issues in the existing `LunCmd/FreeNAS.pm` BEFORE porting to new architecture

Tasks (from plan-002-code-review.md):
- [ ] Fix #4: Regex bug in method validation (`$method !~ /^(?:GET|DELETE|POST)$/`)
- [ ] Fix #1: Rollback on failure in `run_create_lu` and `run_modify_lu` (ADR-004)
- [ ] Fix #3: `$runawayprevent` scope; fix `$freenas_rest_connection->{$apihost}` check
- [ ] Fix #11: Store `$product_name` per-host in `$freenas_server_list`
- [ ] Fix #2: Replace `eval $value` with explicit substitution map
- [ ] Fix #6: Per-request LUN list cache
- [ ] Fix #5: Log warning when SSL verification disabled
- [ ] Fix #8: Consistent taint validation on API response data
- [ ] Improve logging (remove "FreeNAS::" naming in syslog messages, add context)
- [ ] Remove debug `console.warn()` from pvemanagerlib patches
- [ ] Fix `postinst` `&> /dev/null` → redirect to log file

### Phase 3 — Custom Storage Plugin (`TrueNASPlugin.pm`)

**Goal**: New `PVE::Storage::Custom::TrueNASPlugin` with full plugin interface

Starting from `perl5/PVE/Storage/Custom/FreeNAS.pm` (existing unfinished file):

- [ ] Remove duplicate `properties()` and `options()` subs (#9)
- [ ] Implement `type()` → `'truenas'`
- [ ] Implement `properties()` with all TrueNAS-specific fields (see ADR-005)
- [ ] Implement `options()` including new truenas fields as optional
- [ ] Implement `status()` — pool stats via TrueNAS API v2.0 (`GET /api/v2.0/pool/dataset`)
- [ ] Implement `list_images()` — zvol listing via TrueNAS API
- [ ] Implement `alloc_image()` — create zvol + iSCSI extent + targetextent (with rollback)
- [ ] Implement `free_image()` — delete extent (force=true) + zvol (with logging)
- [ ] Implement `activate_volume()` — `iscsiadm` login
- [ ] Implement `deactivate_volume()` — `iscsiadm` logout
- [ ] Implement `path()` — find device from NAA/wwid after iSCSI login
- [ ] Implement `volume_resize()` — resize zvol via TrueNAS API + re-present LUN
- [ ] Port hardened API client from Phase 2 into TrueNASPlugin.pm (or keep as shared module)
- [ ] Integrate Bearer Token as default auth (ADR-005)

### Phase 4 — Standalone UI (`truenas-plugin.js`)

**Goal**: Full Ext.js panel for the 'truenas' storage type; loaded via one-line template patch

- [ ] Research: confirm `index.html.tpl` is the right injection point in PVE 8.x
- [ ] Write `pve-manager/js/truenas-plugin.js`:
  - `Ext.define('PVE.storage.TrueNASInputPanel', {...})`
  - Fields: API host, Bearer Token toggle, secret/confirm, username (conditional), SSL, pool, portal, target
  - Controller logic for field visibility (show/hide username based on token toggle)
  - Form submit/load value mapping (compat: `freenas_password` → `truenas_secret`)
- [ ] Write `index.html.tpl` patch (minimal: one `<script>` tag line)
- [ ] Test on lab PVE 8.x node

### Phase 5 — New Package (`v3.x`) + Migration

- [ ] Update `packaging/DEBIAN/control` (no `git` or `librest-client-perl` dependency)
- [ ] Update `packaging/DEBIAN/postinst` (Phase 0 design above — no patches, just cp)
- [ ] `packaging/DEBIAN/postrm` — remove Custom/*.pm, LunCmd/TrueNAS.pm, truenas-plugin.js, reverse index.html.tpl patch
- [ ] Migration guide in README: how to move from v2.x (ZFS-over-iSCSI + freenas provider) to v3.x (`truenas` storage type)
- [ ] Update Cloudsmith + GitHub Pages with v3.x packages
- [ ] Update README to point at GitHub Pages repo as primary

### Phase 6 — SSH Elimination (stretch goal)

**Goal**: Remove the SSH key requirement for ZFS pool listing

Currently, ZFS pool listing uses SSH (via `ZFSPoolPlugin.pm` upstream, not our code). The TrueNAS v2.0 API can return pool stats and dataset listings, so our custom plugin can return pool `status()` without SSH. The only remaining SSH need is in Proxmox's own ZFSPoolPlugin which we don't control.

If our plugin handles the pool listing entirely internally (using the API), we may be able to advise users to NOT configure SSH at all — needs investigation against the actual Proxmox boot and storage scan flow.

---

## Open Questions Before Implementation Starts

1. Does `index.html.tpl` exist at a known stable path in PVE 8.x? (need lab access)
2. Does PVE auto-pick up `Custom::*` plugins without any additional registration in pvemanagerlib.js?
3. Does `Ext.define('PVE.storage.TrueNASInputPanel')` get auto-wired to `type='truenas'` storage, or does pvemanagerlib.js need a registration entry?
4. Are there TrueNAS API v2.0 endpoints for creating/deleting zvols (not just iSCSI)? (needed for Phase 3)

Items 1-3 can be answered once the lab PVE 8.x node is up.
Item 4: checking TrueNAS API docs — `POST /api/v2.0/pool/dataset` with `type=VOLUME` and `volsize` should work.
