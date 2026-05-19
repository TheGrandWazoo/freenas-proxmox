# TrueNAS ZFS-over-iSCSI Plugin for Proxmox VE

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![GitHub release (latest SemVer)](https://img.shields.io/github/v/release/TheGrandWazoo/freenas-proxmox?sort=semver)](https://github.com/TheGrandWazoo/freenas-proxmox/releases/latest)
[![GitHub Workflow Status](https://img.shields.io/github/actions/workflow/status/TheGrandWazoo/freenas-proxmox/build.yml?label=build)](https://github.com/TheGrandWazoo/freenas-proxmox/actions/workflows/build.yml)
[![GitHub issues](https://img.shields.io/github/issues/TheGrandWazoo/freenas-proxmox)](https://github.com/TheGrandWazoo/freenas-proxmox/issues)
[![GitHub Sponsors](https://img.shields.io/github/sponsors/TheGrandWazoo?label=Sponsors)](https://github.com/sponsors/TheGrandWazoo)

A Proxmox VE storage plugin that manages ZFS-over-iSCSI volumes on TrueNAS (CORE and SCALE) through the TrueNAS REST API — no SSH-based LUN management, no `iscsiadm` scripting.

---

## Table of Contents

- [How It Works](#how-it-works)
- [Compatibility](#compatibility)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Configuration](#configuration)
- [Upgrading](#upgrading)
- [Uninstalling](#uninstalling)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [Support the Project](#support-the-project)
- [License](#license)

---

## How It Works

Proxmox VE's built-in ZFS-over-iSCSI storage type uses SSH to manage LUNs on the storage server. This plugin replaces that SSH-based management layer with direct calls to the **TrueNAS REST API**, giving you:

- API token (Bearer) or username/password authentication
- Automatic TrueNAS API version detection (v1 and v2)
- Support for both TrueNAS CORE and TrueNAS SCALE
- Proper rollback when operations fail (no dangling iSCSI extents)

> **Note:** Proxmox still uses `iscsiadm` to connect and disconnect the iSCSI session on the Proxmox host itself — that part is handled by the core Proxmox code and does not require SSH. The SSH keys documented in the [Proxmox ZFS-over-iSCSI wiki](https://pve.proxmox.com/wiki/Storage:_ZFS_over_iSCSI) are still required for the ZFS pool listing step.

---

## Compatibility

### Version Matrix

| Plugin Version | Proxmox VE | TrueNAS CORE | TrueNAS SCALE | Status |
|:--------------:|:----------:|:------------:|:-------------:|:------:|
| **3.x** *(upcoming)* | 8.x, 9.x | 13.0-U6+ | Cobia (23.10)+, Dragonfish (24.04)+ | In development |
| **2.x** *(current)* | 7.x ⚠️, 8.0–8.3 ✅, 8.4.x ✅ | 11.3+ | 22.02+ | Active |
| **1.x** *(legacy)* | 5.x, 6.x | 11.x | — | Unsupported |

### Important Version Notices

> **Proxmox VE 7 users**
>
> v2.x is the **last release series that supports PVE 7**. PVE 7 support is best-effort only — no new patches will be developed for it.
>
> **Do not upgrade to v3.0** when it releases — v3.0 requires Proxmox VE 8 or later. Stay on the latest v2.x release.

> **Proxmox VE 8 users**
>
> Proxmox VE 8 reaches **end-of-life on 2026-08-31**. Plan your upgrade to PVE 9 before that date.
>
> v2.x works on PVE 8. When you upgrade to PVE 9, migrate to v3.0 (coming before the EOL date).

> **Proxmox VE 9+ users**
>
> v2.x is **not supported on PVE 9**. Use v3.0 when it is released. Do not install v2.x on a PVE 9 node.

> **Proxmox VE 5 or 6 users**
>
> These versions are not supported. PVE 5 reached end-of-life in 2019, PVE 6 in 2022. Please upgrade your Proxmox VE installation.

Check the [Releases page](https://github.com/TheGrandWazoo/freenas-proxmox/releases) for the specific Proxmox and TrueNAS versions tested against each release.

---

## Prerequisites

Before installing, ensure the following are in place on your **Proxmox VE node**:

1. **SSH keys** configured between Proxmox and TrueNAS — required for ZFS pool listing by the Proxmox core (see the [Proxmox wiki](https://pve.proxmox.com/wiki/Storage:_ZFS_over_iSCSI), section starting with `mkdir /etc/pve/priv/zfs`).

2. On **TrueNAS**, an iSCSI target and initiator group must exist and be configured. The plugin manages extents and target-to-extent mappings, but the target itself must be pre-created.

3. On **TrueNAS SCALE** or **TrueNAS CORE 13+**, generate an API key:
   - TrueNAS SCALE: *System Settings → API Keys → Add*
   - TrueNAS CORE: *System → API Keys → Add*
   
   Copy the key — you will need it during storage configuration in Proxmox.

---

## Installation

### Stable Release

Add the repository and install:

```bash
# Import the GPG key
curl -fsSL https://dl.cloudsmith.io/public/ksatechnologies/truenas-proxmox/gpg.284C106104A8CE6D.key \
  | gpg --dearmor \
  | tee /usr/share/keyrings/ksatechnologies-truenas-proxmox-keyring.gpg > /dev/null

# Add the repository
cat > /etc/apt/sources.list.d/ksatechnologies-repo.list << 'EOF'
deb [signed-by=/usr/share/keyrings/ksatechnologies-truenas-proxmox-keyring.gpg] \
  https://dl.cloudsmith.io/public/ksatechnologies/truenas-proxmox/deb/debian any-version main
EOF

# Install
apt update && apt install freenas-proxmox
```

### Testing / Beta Release

For early access to new features (may be unstable):

```bash
# Import the GPG key
curl -fsSL https://dl.cloudsmith.io/public/ksatechnologies/truenas-proxmox-testing/gpg.CACC9EE03F2DFFCC.key \
  | gpg --dearmor \
  | tee /usr/share/keyrings/ksatechnologies-truenas-proxmox-testing-keyring.gpg > /dev/null

# Add the repository
cat > /etc/apt/sources.list.d/ksatechnologies-testing-repo.list << 'EOF'
deb [signed-by=/usr/share/keyrings/ksatechnologies-truenas-proxmox-testing-keyring.gpg] \
  https://dl.cloudsmith.io/public/ksatechnologies/truenas-proxmox-testing/deb/debian any-version main
EOF

# Install
apt update && apt install freenas-proxmox
```

---

## Configuration

After installation, **refresh your browser** to load the updated Proxmox UI. Then add a new ZFS-over-iSCSI storage:

1. Navigate to **Datacenter → Storage → Add → ZFS over iSCSI**
2. Set **iSCSI Provider** to **FreeNAS/TrueNAS API**
3. Fill in the storage fields — see below for authentication options

### Authentication: API Token (Recommended)

| Field | Value |
|-------|-------|
| Portal | IP or hostname of your TrueNAS server |
| Target | The iSCSI target IQN |
| Pool | The ZFS pool name |
| Use SSL | Enabled (recommended) |
| API Host | Leave blank to use Portal IP, or specify a separate management IP |
| Use Token Auth | **Enabled** |
| API Token | Paste the TrueNAS API key you generated |

### Authentication: Username / Password (Legacy)

| Field | Value |
|-------|-------|
| Use Token Auth | Disabled |
| Username | TrueNAS API user (usually `root`) |
| Password | TrueNAS user password |

> **Security note:** Username/password authentication sends credentials on every API call. API token authentication is preferred and may be required in future TrueNAS releases.

---

## Upgrading

The package integrates with Proxmox VE's standard upgrade mechanism. On `apt upgrade`, the package will automatically re-apply any patches needed after a Proxmox VE update:

```bash
apt update && apt full-upgrade
```

---

## Uninstalling

```bash
apt remove freenas-proxmox
```

This removes the plugin and reverses all patches, returning your Proxmox VE installation to its unmodified state. Any storage configurations using this plugin should be removed from Proxmox before uninstalling.

---

## Troubleshooting

### After install, the "FreeNAS/TrueNAS API" option is not visible

Refresh your browser (force-refresh with Ctrl+Shift+R or Cmd+Shift+R). The Proxmox UI JavaScript is cached aggressively.

### Storage shows as unavailable / API connection fails

Check `journalctl -f` or `/var/log/syslog` on the Proxmox node — the plugin logs all API calls and errors with `[FreeNAS::API::]` prefixes.

Common causes:
- Wrong API host or portal IP
- SSL mismatch (try toggling SSL on/off)
- API token expired or revoked
- TrueNAS iSCSI service not running

### Dangling extents on TrueNAS after a failed operation

If you see iSCSI extents in TrueNAS that are not associated with any target, they can be safely deleted from the TrueNAS UI. The v3.x plugin release adds automatic rollback to prevent this.

### Filing a Bug Report

Please use the [GitHub issue tracker](https://github.com/TheGrandWazoo/freenas-proxmox/issues) and include the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md). Include relevant log lines from `syslog` (search for `FreeNAS::`).

---

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

For significant changes, open an issue first to discuss the approach.

---

## Support the Project

If this plugin saves you time, consider supporting its development:

- **GitHub Sponsors**: [github.com/sponsors/TheGrandWazoo](https://github.com/sponsors/TheGrandWazoo)
- **PayPal**: [Donate via PayPal](https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=TCLNEMBUYQUXN&source=url)

Donor support has funded a 4-node Proxmox cluster and TrueNAS test lab used for development and validation. See [DONORS.md](DONORS.md) for a full list of donors.

---

## License

Copyright (c) 2020 KSA Technologies, LLC

This program is free software: you can redistribute it and/or modify it under the terms of the [GNU Affero General Public License](LICENSE) as published by the Free Software Foundation, version 3.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
