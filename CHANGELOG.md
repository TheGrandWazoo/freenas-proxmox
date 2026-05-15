# Changelog

All notable changes to this project will be documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) independent of Proxmox VE or TrueNAS versions.
See each [GitHub Release](https://github.com/TheGrandWazoo/freenas-proxmox/releases) for the specific Proxmox VE and TrueNAS versions supported.

---

## [Unreleased] — v3.0.0

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

See the [commit history](https://github.com/TheGrandWazoo/freenas-proxmox/commits/master) for earlier changes.
