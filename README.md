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

### v3.0 (upcoming)

v3.0 is a fully API-driven custom storage plugin. No SSH keys required.

1. On **TrueNAS**, ensure the iSCSI service is running and an iSCSI **portal** and **initiator group** are configured. The plugin creates per-VM iSCSI targets automatically — you do not need to pre-create a target.

2. Generate a TrueNAS API key:
   - TrueNAS SCALE: *System Settings → API Keys → Add*
   - TrueNAS CORE 13: *gear icon (top-right) → API Keys → Add*

   Copy the key — you will need it during storage configuration in Proxmox.

### v2.x (current stable)

1. **SSH keys** configured between Proxmox and TrueNAS — required for ZFS pool listing by the Proxmox core (see the [Proxmox wiki](https://pve.proxmox.com/wiki/Storage:_ZFS_over_iSCSI), section starting with `mkdir /etc/pve/priv/zfs`).

2. On **TrueNAS**, an iSCSI **target** and **initiator group** must exist and be configured. The plugin manages extents and target-to-extent mappings, but the target itself must be pre-created.

3. On **TrueNAS SCALE** or **TrueNAS CORE 13+**, generate an API key:
   - TrueNAS SCALE: *System Settings → API Keys → Add*
   - TrueNAS CORE 13: *gear icon (top-right) → API Keys → Add*

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

### ZFS Block Size

The **ZFS Blocksize** field controls the `-b` argument passed to `zfs create` when Proxmox provisions a new zvol on TrueNAS. Set this when adding the storage — it cannot be changed afterward without editing the config directly.

| TrueNAS Product | Recommended blocksize |
|:----------------|:----------------------|
| TrueNAS SCALE (any version) | **16k (16384)** |
| TrueNAS CORE | **8k (8192)** |

TrueNAS SCALE ships a newer ZFS that requires a minimum block size of 16k. If you leave this at the Proxmox default of 8k on a SCALE system, every disk creation will log:

```
Warning: volblocksize (8192) is less than the default minimum block size (16384).
To reduce wasted space a volblocksize of 16384 is recommended.
```

The disk is created successfully despite this warning, but the suboptimal block size wastes space due to internal ZFS padding on every write.

**Fixing an existing storage entry:**

Edit `/etc/pve/storage.cfg` on any cluster node and change `blocksize 8192` to `blocksize 16384` for your TrueNAS SCALE storage entry. No data migration is needed — only newly created zvols use the updated value. Existing zvols are unaffected.

> **Note:** Automatic blocksize detection based on TrueNAS version is planned for v2.4.0 (see [#241](https://github.com/TheGrandWazoo/freenas-proxmox/issues/241)).

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

### Understanding what this plugin does — and does not — do

Before reporting an issue, it helps to know which layer the error is coming from. This plugin is an **orchestrator**: it calls the TrueNAS REST API to provision resources (create zvols, iSCSI extents, and target mappings). It does not carry data. The actual disk I/O path — QEMU reading and writing blocks — runs directly between Proxmox and TrueNAS over iSCSI, with no involvement from this plugin.

There are three distinct layers where errors can appear:

**Layer 1 — Plugin (TrueNAS REST API)**

The plugin called the TrueNAS API and got an error, or the API was unreachable. These errors come from the plugin code and appear in the Proxmox task log with prefixes like `freenas-proxmox:` or `[TrueNAS::]`.

Common causes:
- Wrong API host IP or hostname
- HTTP vs HTTPS mismatch (toggle **Use SSL**)
- API token expired, revoked, or not entered correctly
- TrueNAS iSCSI service not running
- TrueNAS API service not reachable from the Proxmox node

Example log line:
```
freenas-proxmox: Unable to connect to the TrueNAS API at '192.168.1.10' using HTTPS (500)
```

**Layer 2 — iSCSI / QEMU data path**

The VM's QEMU process (v3.0) or the Proxmox kernel iSCSI stack (v2.x) failed to connect or lost its session to TrueNAS. These errors come from QEMU or `iscsiadm` — not from this plugin.

In **v3.0**, look for QEMU log lines referencing `iscsi://` paths. In **v2.x**, look for `iscsiadm` lines in syslog.

Common causes:
- TrueNAS iSCSI service stopped while a VM was running
- Initiator group does not permit the Proxmox node's IP
- Network path to the iSCSI portal is down
- CHAP authentication configured on the TrueNAS target but not in Proxmox (note: this plugin does not configure CHAP — it must be set to None or configured separately)

Example log line (v2.x):
```
iscsiadm: No active sessions.
```

**Layer 3 — Proxmox core storage stack**

Errors from PVE's own storage subsystem — ZFSPlugin.pm, pvedaemon, pool listing via SSH, or storage.cfg parsing. These exist regardless of which iSCSI plugin you use.

Common causes:
- SSH keys not configured between Proxmox and TrueNAS (required for ZFS pool listing — see [Prerequisites](#prerequisites))
- `storage.cfg` syntax error
- `pvedaemon` or `pvestatd` service crashed

Example log line:
```
unable to run command '/usr/bin/ssh ... zfs list ...': exit code 255
```

**Quick triage:**

| Symptom | Likely layer | First check |
|---------|-------------|-------------|
| Disk creation fails, API error in task log | Plugin (Layer 1) | API key, SSL setting, TrueNAS API reachable |
| Disk created on TrueNAS but Proxmox reports error | Plugin (Layer 1) | syslog for `freenas-proxmox:` lines |
| VM won't start, iSCSI session error | iSCSI/QEMU (Layer 2) | TrueNAS iSCSI service, initiator group ACL |
| Storage shows unavailable, pool listing fails | Proxmox core (Layer 3) | SSH key setup, `pvedaemon` service |
| Kernel errors after disk deletion (v2.x) | iSCSI/Proxmox (Layer 2/3) | `iscsiadm -m session -R` to rescan |

---

### After install, the "FreeNAS/TrueNAS API" option is not visible

Refresh your browser (force-refresh with Ctrl+Shift+R or Cmd+Shift+R). The Proxmox UI JavaScript is cached aggressively.

### Storage shows as unavailable / API connection fails

Check `journalctl -f` or `/var/log/syslog` on the Proxmox node — the plugin logs all API calls and errors with `[FreeNAS::API::]` prefixes.

Common causes:
- Wrong API host or portal IP
- SSL mismatch (try toggling SSL on/off)
- API token expired or revoked
- TrueNAS iSCSI service not running

### "volblocksize is less than the default minimum block size" warning on disk creation

This warning appears on TrueNAS SCALE when a zvol is created with a blocksize below 16k.

**v2.4.0 and later:** the plugin automatically detects the correct blocksize from the TrueNAS API and corrects it. If you see a line like `freenas-proxmox: blocksize 8192 < recommended 16384 -- correcting storage '...'` in the task log, the correction was applied and the disk was created correctly. The storage config is also updated automatically so subsequent disk creations will be silent.

**v2.3.x and earlier:** see [ZFS Block Size](#zfs-block-size) — manually set the blocksize to `16k` for SCALE storages.

### API key stops working after upgrading TrueNAS SCALE to 25.04

TrueNAS SCALE 25.04 **revokes all existing API keys** that were created with whitelisted methods during the upgrade. If you are using `truenas_token_auth` and your storage shows as unavailable after a SCALE 25.04 upgrade, your API key was revoked.

**Fix:**
1. Log into the TrueNAS SCALE web UI
2. Go to **Credentials → API Keys** and generate a new API key
3. In Proxmox, edit the affected storage (**Datacenter → Storage → Edit**) and paste the new key into the **API Secret / Token** field

**Additionally**, TrueNAS SCALE 25.04 enforces HTTPS for API key authentication — keys transmitted over plain HTTP are automatically revoked. Ensure **Use SSL** is enabled in your Proxmox storage config when using token auth.

> **Note:** TrueNAS SCALE 25.04 also deprecates the REST API used by this plugin (v2.x). Full removal is planned for SCALE 26.x. Plugin v3.0.0 will add WebSocket JSON-RPC 2.0 support. See [issue #243](https://github.com/TheGrandWazoo/freenas-proxmox/issues/243).

### Disk size in Proxmox shows larger than what I entered

This is expected. Proxmox creates disks in **GiB** (gibibytes, base-2) but displays them in **GB** (gigabytes, base-10) in some views.

| Unit | Base | 1 unit = |
|------|------|----------|
| GiB (gibibyte) | 2¹⁰ = 1024 | 1,073,741,824 bytes |
| GB (gigabyte) | 10³ = 1000 | 1,000,000,000 bytes |

When you enter **80 GiB** in the Proxmox disk creation dialog, the zvol is created as exactly 85,899,345,920 bytes. TrueNAS reports that in decimal: **85.90 GB**. The disk inside the VM is still exactly 80 GiB — nothing is lost or added.

A quick reference:

| Entered in Proxmox | TrueNAS / decimal display |
|--------------------|---------------------------|
| 10 GiB | 10.74 GB |
| 32 GiB | 34.36 GB |
| 80 GiB | 85.90 GB |
| 100 GiB | 107.37 GB |
| 500 GiB | 536.87 GB |
| 1 TiB | 1,099.51 GB (≈ 1.10 TB) |

### Dangling extents on TrueNAS after a failed operation

If you see iSCSI extents in TrueNAS that are not associated with any target, they can be safely deleted from the TrueNAS UI. v2.3.0 and later automatically roll back and clean up after a failed LUN creation.

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
