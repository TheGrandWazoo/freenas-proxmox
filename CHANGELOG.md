# Changelog

All notable changes to this project will be documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) independent of Proxmox VE or TrueNAS versions.
See each [GitHub Release](https://github.com/TheGrandWazoo/truenas-proxmox/releases) for the specific Proxmox VE and TrueNAS versions supported.

---

## [4.0.0] — 2026-08-31 — Rivendell

See [ADR-012](.claude/cos/adrs/ADR-012-websocket-transport-v4.md) (Accepted)
and [ADR-013](.claude/cos/adrs/ADR-013-branching-strategy.md) for the full
design and live-verification history.

### Added
- WebSocket JSON-RPC 2.0 transport for TrueNAS SCALE 25.04+ (`_api_ws`,
  `_ws_connect`, `_ws_call`, `_transport()`), auto-detected per host —
  `storage.cfg` is unchanged either way. TrueNAS CORE and SCALE < 25.04
  continue to use the existing REST v2.0 transport, unmodified (#243)
- New dependency: `libanyevent-websocket-client-perl` (pulls in
  `libanyevent-perl`), added to `packaging/DEBIAN/control.j2` and CI's lint
  job — only affects the v4 line (`v4`/`rivendell` apt dist), v3.x is
  unaffected (archived at `release/3.x` per ADR-013)

### Verified (live, against real TrueNAS hosts)
- Every read (query) call the plugin makes, across three TrueNAS SCALE
  versions (25.10.3.1, 25.10.6, 25.04.2.6)
- Full `alloc_image`/`path`/`volume_size_info`/`free_image` write cycle —
  target, extent, targetextent, and dataset create+delete, zero orphans
- Full snapshot cycle — `volume_snapshot`/`_info`/`_rollback`/`_delete`
- REST-path regression check against TrueNAS CORE (a real production box) —
  confirms the new `_api()` dispatcher doesn't break hosts that never touch
  WebSocket
- Multipath (`truenas-proxmox-multipath`) over the WebSocket transport —
  zero code changes needed to `TrueNASMultipath.pm`, confirmed via a full
  `activate_volume`/`deactivate_volume` cycle producing a real 2-path
  `dm-multipath` device

### Fixed (caught during the above verification, before ever shipping)
- `_transport()`'s first draft checked `/system/product_type eq 'SCALE'` to
  distinguish CORE from SCALE — that field returns the license tier (e.g.
  `COMMUNITY_EDITION`), not the product family. Fixed to parse
  `/system/version`'s magnitude instead
- `iscsi.target.delete`/`iscsi.targetextent.delete` were passed a
  regex-captured id as a string; Pydantic requires an integer
- `iscsi.extent.delete(id, remove, force)` is positional, not
  `(id, {force=>bool})` — the REST-style options hash was landing in the
  `remove` slot

### Known deferred
- #249 (per-variant `TrueNAS-Core.pm`/`TrueNAS-Scale.pm` dispatch) — explicitly
  out of scope for this release, tracked as possible v4.1/v5.0 work

---

## [3.2.5] — 2026-08-23

### Fixed
- HA-managed VMs on `truenas-multipath` storage could fail to start after installing or upgrading `truenas-proxmox-multipath` — its postinst/postrm had the same gap #179 fixed in the main package: only `pvedaemon`/`pveproxy` were restarted, never `pvestatd`/`pve-ha-lrm`/`pve-ha-crm`. Verified live on pve01/02/03-hq — all five daemons now restart cleanly on install (#287)

### Documentation
- README, getting-started.md, and the in-UI help panel updated for TrueNAS SCALE 25.04's UI changes (API key screen moved, standalone portal/initiator-group screen replaced by the iSCSI Share wizard) and to match the actual v3 storage panel fields, which had drifted from the v2.x field set still described in the docs (#286)
- deb822 (`.sources`) format added as the primary apt install instructions for PVE 9 / Debian trixie, across README, getting-started.md, and upgrade-paths.md; the one-liner `.list` format is kept as a fallback for PVE 8 / bookworm (#285)

---

## [3.2.4] — 2026-08-01

### Fixed
- HA-managed VMs on TrueNAS storage could fail to start after installing or upgrading the plugin — `postinst`/`postrm` only restarted `pvedaemon`/`pveproxy` and never `pve-ha-lrm`/`pve-ha-crm`/`pvestatd`; all are now restarted on install/remove, with a regression test added (#179)

---

## [3.2.3] — 2026-06-27

### Documentation
- Documented the one-time apt codename prompt existing users see when upgrading past v3.2.2 (`apt update --allow-releaseinfo-change`)
- Added a SCALE 25.04 portal PUT port field callout (#280)
- Updated the bug report template to request `pveversion -v` output and a `journalctl` log command

---

## [3.2.2] — 2026-06-23

### Fixed
- `api()` bumped to 15 to match PVE 9's storage APIVER, silencing the "implementing an older storage API" warning seen on PVE 9

---

## [3.2.1] — 2026-06-22

### Added
- Apt dist codenames per major version: `limelight` (v2), `error` (v3), `rivendell` (v4)

### Fixed
- Codename alias directories weren't generated correctly, breaking `error`/`limelight`/`rivendell` entries in `sources.list`
- `cp -r` overwrite bug when creating the `dists/error` codename alias

---

## [3.2.0] — 2026-06-20

### Added
- Multipath iSCSI support, shipped as a separate, independently installable plugin — `truenas-proxmox-multipath` / `TrueNASMultipath.pm` — distributed via its own apt component so it doesn't touch the base plugin (#256)
- UI panel for the `truenas-multipath` storage type (#278)

### Fixed
- `multipath.conf` now managed safely via a tagged `BEGIN`/`END` block; pre-existing unmanaged devices blocks are stripped before injecting the managed stanza
- `qemu_blockdev_options` delegated to `Plugin.pm` for the `host_device` path
- Multipath `activate_volume` and `naa` field lookup in `_find_extent`
- Stale version accumulation in the apt pool/multipath/testing dists before publish

---

## [3.1.0] — 2026-06-07

### Added
- ZFS snapshot interface via the TrueNAS REST API (#234)
- GitHub Pages apt repository as the testing dist track; Cloudsmith testing track retired (#272)
- ADR-010: per-major-version apt dist tracks (supersedes ADR-003)
- ADR-011: apt components for optional feature packages
- Cloudsmith → GitHub Pages migration script and upgrade-paths documentation

### Changed
- `api()` bumped to 14 for PVE 9 compatibility
- Stable v3+ releases no longer published to Cloudsmith

### Fixed
- `parse_volname` now accepts the state-volume naming pattern (#234)
- Debian changelog added to both packages (#273)
- Testing dist channel name and broken README badges (#275)
- `Filename:` prefix restored in CI apt Packages generation (#274)
- gh-pages push now uses `GITHUB_TOKEN` (previous `ACCESS_TOKEN` had expired)
- Apt arch warning in the Cloudsmith migration script

---

## [3.0.0] — 2026-05-31

### Added
- New `PVE::Storage::Custom::TrueNASPlugin` — proper Proxmox VE custom storage type (no more ZFSPlugin.pm patching)
- Standalone `truenas-plugin.js` UI panel — eliminates patching of `pvemanagerlib.js`
- Automatic rollback of TrueNAS API changes when operations partially fail (fixes dangling iSCSI extents)
- Bearer Token authentication as the primary auth method
- Per-host product name tracking (fixes behavior when multiple TrueNAS backends are configured)
- GitHub Pages apt repository as primary distribution channel

### Changed
- Package no longer requires `git` or `patch` at install time
- Package no longer downloads from GitHub at install time (files embedded in `.deb`)
- Replaced `REST::Client` with `LWP::UserAgent` (already present in Proxmox VE)
- Renamed module internally from `FreeNAS` to `TrueNAS` namespace
- License changed from MIT to AGPL-3.0

### Fixed
- Method validation regex in `freenas_api_call` had incorrect Perl operator precedence — validation never fired
- `$runawayprevent` was a module global that could persist incorrectly across multiple connections
- SSL certificate verification was disabled silently without logging a warning
- `eval $value` template substitution replaced with explicit substitution map

### Removed
- `stable-5/`, `stable-6/`, `stable-7/` version-specific patch directories (superseded by new architecture)
- Dependency on `librest-client-perl`
- Dependency on `git`

---

## [2.3.0] — 2024-01-07

### Added
- Bearer Token authentication support (`truenas_token_auth` flag, `truenas_secret` field)
- TrueNAS SCALE version string parsing

### Changed
- Renamed `freenas_password` to `truenas_secret` to represent either a password or token
- Indentation and whitespace cleanup

---

## [2.2.0] — 2023-08-16

### Fixed
- Repository issues (#151, #152, #153)
- PayPal donation link
- `postinst` Windows-style line ending issue (#149)

### Changed
- Added `systemctl restart pvescheduler.service` to post-install

---

## [2.1.x] and Earlier

See the [commit history](https://github.com/TheGrandWazoo/truenas-proxmox/commits/master) for earlier changes.
