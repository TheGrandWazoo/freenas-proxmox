# TrueNAS ZFS-over-iSCSI Plugin for Proxmox VE

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![GitHub release (latest SemVer)](https://img.shields.io/github/v/release/TheGrandWazoo/freenas-proxmox?sort=semver)](https://github.com/TheGrandWazoo/freenas-proxmox/releases/latest)
[![GitHub Workflow Status](https://img.shields.io/github/actions/workflow/status/TheGrandWazoo/freenas-proxmox/build.yml?branch=release%2F3.x&label=build)](https://github.com/TheGrandWazoo/freenas-proxmox/actions/workflows/build.yml)
[![GitHub issues](https://img.shields.io/github/issues/TheGrandWazoo/freenas-proxmox)](https://github.com/TheGrandWazoo/freenas-proxmox/issues)
[![GitHub Sponsors](https://img.shields.io/github/sponsors/TheGrandWazoo?label=Sponsors)](https://github.com/sponsors/TheGrandWazoo)

> This plugin is maintained by one person and has 4 million downloads — used in production at ISPs and MSPs worldwide. If it saves you time or headaches, [please consider sponsoring](https://github.com/sponsors/TheGrandWazoo) to keep it actively maintained and funded.

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

This plugin is a native `PVE::Storage::Custom` type — Proxmox discovers it automatically and treats it like any other storage backend. When you create a VM disk, the plugin calls the **TrueNAS REST API** to provision a ZFS volume (zvol) and a dedicated per-VM iSCSI target, then hands Proxmox an `iscsi://` path. QEMU opens that path directly — no SSH, no `iscsiadm`, no kernel iSCSI sessions on the Proxmox host.

- Bearer Token (API key) authentication — no username/password, no SSH keys
- Per-VM iSCSI targets (`proxmox-vm-<vmid>`) — removing one disk never affects other VMs
- Automatic rollback when operations fail (no dangling iSCSI extents)
- Supports TrueNAS CORE 13.x and TrueNAS SCALE 24.10–25.10

---

## Compatibility

### Version Matrix

| Plugin Version | Proxmox VE | TrueNAS CORE | TrueNAS SCALE | Status |
|:--------------:|:----------:|:------------:|:-------------:|:------:|
| **3.x** *(stable)* | 8.4.x ✅, 9.x ✅ | 13.0-U6+ ✅ | Electric Eel (24.10) ✅, Fangtooth (25.04) ✅, Goldeye (25.10) ✅ | Stable |
| **2.x** *(stable)* | 7.x ⚠️, 8.0–8.3 ✅, 8.4.x ✅ | 11.3+ | 22.02+ | Active |
| **1.x** *(legacy)* | 5.x, 6.x | 11.x | — | Unsupported |

Tested combinations are marked ✅. Untested combinations may work but are not validated. Check the [Releases page](https://github.com/TheGrandWazoo/freenas-proxmox/releases) for the specific versions tested against each release.

### Important Version Notices

> **Proxmox VE 7 users**
>
> v2.x is the **last release series that supports PVE 7**. PVE 7 support is best-effort only — no new patches will be developed for it.
>
> v3.0 requires Proxmox VE 8 or later. Stay on the latest v2.x release.

> **Proxmox VE 8 users**
>
> v3.0 beta is tested and working on PVE 8.4.x. This is the recommended version for running v3.0 beta.
>
> Proxmox VE 8 reaches **end-of-life on 2026-08-31**. PVE 9 support is targeted for v3.1.0, planned well before that date.

> **Proxmox VE 9+ users**
>
> v3.0 beta has a **known issue on PVE 9.x** — VMs may fail to start due to a LUN type mismatch in QEMU's blockdev layer ([#266](https://github.com/TheGrandWazoo/freenas-proxmox/issues/266)). PVE 9.x support is actively being investigated for **v3.1.0**.
>
> v2.x is not supported on PVE 9. Stay on PVE 8.x until v3.1.0 is available.

> **Proxmox VE 5 or 6 users**
>
> These versions are not supported. PVE 5 reached end-of-life in 2019, PVE 6 in 2022. Please upgrade your Proxmox VE installation.

Check the [Releases page](https://github.com/TheGrandWazoo/truenas-proxmox/releases) for the specific Proxmox and TrueNAS versions tested against each release.

---

## Prerequisites

### v3.0 (beta)

v3.0 is a fully API-driven custom storage plugin. No SSH keys required.

1. On **TrueNAS**, ensure the iSCSI service is running and an iSCSI **portal** and **initiator group** are configured. The plugin creates per-VM iSCSI targets automatically — you do not need to pre-create a target.

   > **TrueNAS SCALE 25.04+:** the UI no longer exposes a standalone portal/initiator-group configuration screen — only the full iSCSI **Share wizard** (*Shares → iSCSI → Add*). Run the wizard once to create a throwaway share (this leaves a usable portal and initiator group behind), then delete the zvol/share the wizard created. The portal and initiator group persist after that deletion, and the plugin takes over from there. See [docs/getting-started.md §2.3](docs/getting-started.md#23-iscsi-service-on-truenas) for the full walkthrough.

2. Generate a TrueNAS API key:
   - TrueNAS SCALE 25.04+: *Credentials → API Keys → Add*
   - TrueNAS SCALE (pre-25.04): *System Settings → API Keys → Add*
   - TrueNAS CORE 13: *gear icon (top-right) → API Keys → Add*

   Copy the key — you will need it during storage configuration in Proxmox.

> **Known limitation — TPM state disks**
>
> `tpmstate0` (virtual TPM) disks **cannot** be stored on v3.0 iSCSI storage. The `swtpm` backend requires a local filesystem path and cannot use the `iscsi://` URIs that v3.0 provides to QEMU.
>
> If your VM uses Secure Boot or TPM, store the `tpmstate0` disk on a separate storage (e.g. `local-lvm` or NFS). All other disk types — virtio, scsi, IDE, EFI — work normally.
>
> For live VM migration with TPM, the TPM state disk must also be on shared filesystem storage (NFS or CephFS), not on this plugin's storage.

### v2.x (legacy)

> v2.x is no longer the recommended version. See [Migrating from v2.x](docs/migrating-from-v2.md).

1. **SSH keys** configured between each Proxmox node and TrueNAS — required by the Proxmox core for ZFS pool listing (see the [Proxmox wiki](https://pve.proxmox.com/wiki/Storage:_ZFS_over_iSCSI), section starting with `mkdir /etc/pve/priv/zfs`).

2. On **TrueNAS**, a pre-created iSCSI **target** and **initiator group**.

3. A TrueNAS API key (SCALE: *System Settings → API Keys*; CORE 13: *gear icon → API Keys*).

---

## Installation

### Stable Release (v3.x)

```bash
# Import the GPG key
curl -fsSL https://thegrandwazoo.github.io/freenas-proxmox/public.gpg.key \
  | gpg --dearmor \
  | sudo tee /etc/apt/keyrings/truenas-proxmox.gpg > /dev/null

# Add the v3 repository track (deb822 format — recommended for PVE 9 / Debian trixie)
cat << 'SOURCES' | sudo tee /etc/apt/sources.list.d/truenas-proxmox.sources
Types: deb
URIs: https://thegrandwazoo.github.io/freenas-proxmox
Suites: v3
Components: main
Signed-By: /etc/apt/keyrings/truenas-proxmox.gpg
SOURCES

# Install
sudo apt update && sudo apt install truenas-proxmox
```

<details>
<summary>PVE 8 / Debian bookworm — one-liner <code>.list</code> format</summary>

```bash
echo "deb [signed-by=/etc/apt/keyrings/truenas-proxmox.gpg] \
https://thegrandwazoo.github.io/freenas-proxmox v3 main" \
  | sudo tee /etc/apt/sources.list.d/truenas-proxmox.list
```

</details>

`apt upgrade` will deliver v3.x point releases automatically. You will never be
automatically promoted to a future v4 — that requires changing the dist track in
your `sources.list` to `v4`.

> **Existing users — one-time prompt after v3.2.2**
> If `apt update` shows `changed its 'Codename' value from 'v3' to 'error'`, run:
> ```bash
> apt update --allow-releaseinfo-change
> ```
> This happened once when codename aliases were added in v3.2.2. It will not recur.
> Both `v3` (Suite) and `error` (Codename) continue to work in `sources.list`.

### Upgrading from v2.x

**v3.0 is a breaking change.** Do not run `apt upgrade` until you have read the
migration guide — your storage configuration will need to be updated.

See [docs/migrating-from-v2.md](docs/migrating-from-v2.md).

### Staying on v2.x

If you are on v2.x and want to continue receiving v2.x point releases without
risking a v3 upgrade, switch to the `main` dist track (v2.x only):

```bash
# Import the GPG key (if not already done)
curl -fsSL https://thegrandwazoo.github.io/freenas-proxmox/public.gpg.key \
  | gpg --dearmor \
  | sudo tee /etc/apt/keyrings/truenas-proxmox.gpg > /dev/null

# Add the v2 repository track (deb822 format — recommended for PVE 9 / Debian trixie)
cat << 'SOURCES' | sudo tee /etc/apt/sources.list.d/truenas-proxmox.sources
Types: deb
URIs: https://thegrandwazoo.github.io/freenas-proxmox
Suites: main
Components: main
Signed-By: /etc/apt/keyrings/truenas-proxmox.gpg
SOURCES

sudo apt update
```

<details>
<summary>PVE 8 / Debian bookworm — one-liner <code>.list</code> format</summary>

```bash
echo "deb [signed-by=/etc/apt/keyrings/truenas-proxmox.gpg] \
https://thegrandwazoo.github.io/freenas-proxmox main main" \
  | sudo tee /etc/apt/sources.list.d/truenas-proxmox.list
```

</details>

### Migrating from Cloudsmith

> Cloudsmith is being phased out. GitHub Pages is the permanent home for this project's packages.

If you installed from the Cloudsmith apt repo, swap your source to GitHub Pages. Your installed package is not affected — this only changes where future updates come from.

**On v3.x (Cloudsmith stable):**

```bash
# Remove the old Cloudsmith source
sudo rm -f /etc/apt/sources.list.d/truenas-proxmox*.list
sudo rm -f /usr/share/keyrings/ksatechnologies-truenas-proxmox*.gpg

# Import the GitHub Pages GPG key
curl -fsSL https://thegrandwazoo.github.io/freenas-proxmox/public.gpg.key \
  | gpg --dearmor \
  | sudo tee /etc/apt/keyrings/truenas-proxmox.gpg > /dev/null

# Point to the v3 dist track (deb822 format — recommended for PVE 9 / Debian trixie)
cat << 'SOURCES' | sudo tee /etc/apt/sources.list.d/truenas-proxmox.sources
Types: deb
URIs: https://thegrandwazoo.github.io/freenas-proxmox
Suites: v3
Components: main
Signed-By: /etc/apt/keyrings/truenas-proxmox.gpg
SOURCES

sudo apt update
```

<details>
<summary>PVE 8 / Debian bookworm — one-liner <code>.list</code> format</summary>

```bash
echo "deb [signed-by=/etc/apt/keyrings/truenas-proxmox.gpg] \
https://thegrandwazoo.github.io/freenas-proxmox v3 main" \
  | sudo tee /etc/apt/sources.list.d/truenas-proxmox.list
```

</details>

**On v2.x (Cloudsmith stable) — staying on v2:**

```bash
# Remove the old Cloudsmith source
sudo rm -f /etc/apt/sources.list.d/freenas-proxmox*.list /etc/apt/sources.list.d/truenas-proxmox*.list
sudo rm -f /usr/share/keyrings/ksatechnologies-truenas-proxmox*.gpg

# Import the GitHub Pages GPG key
curl -fsSL https://thegrandwazoo.github.io/freenas-proxmox/public.gpg.key \
  | gpg --dearmor \
  | sudo tee /etc/apt/keyrings/truenas-proxmox.gpg > /dev/null

# Point to the v2 dist track (deb822 format — recommended for PVE 9 / Debian trixie; v2.x only, you will never receive a v3 package)
cat << 'SOURCES' | sudo tee /etc/apt/sources.list.d/truenas-proxmox.sources
Types: deb
URIs: https://thegrandwazoo.github.io/freenas-proxmox
Suites: main
Components: main
Signed-By: /etc/apt/keyrings/truenas-proxmox.gpg
SOURCES

sudo apt update
```

<details>
<summary>PVE 8 / Debian bookworm — one-liner <code>.list</code> format</summary>

```bash
echo "deb [signed-by=/etc/apt/keyrings/truenas-proxmox.gpg] \
https://thegrandwazoo.github.io/freenas-proxmox main main" \
  | sudo tee /etc/apt/sources.list.d/truenas-proxmox.list
```

</details>

For a full upgrade path matrix — including what to do when v4 ships — see [docs/upgrade-paths.md](docs/upgrade-paths.md).

---

### Testing / Beta Release

For early access to new features (may be unstable). Beta builds are published on
every push to `release/3.x` — always the latest build, not accumulated history.

```bash
# Import the GPG key (skip if already done for the stable track)
curl -fsSL https://thegrandwazoo.github.io/freenas-proxmox/public.gpg.key \
  | gpg --dearmor \
  | sudo tee /etc/apt/keyrings/truenas-proxmox.gpg > /dev/null

# Add the testing dist track (deb822 format — recommended for PVE 9 / Debian trixie)
cat << 'SOURCES' | sudo tee /etc/apt/sources.list.d/truenas-proxmox.sources
Types: deb
URIs: https://thegrandwazoo.github.io/freenas-proxmox
Suites: testing
Components: main
Signed-By: /etc/apt/keyrings/truenas-proxmox.gpg
SOURCES

sudo apt update && sudo apt install truenas-proxmox
```

<details>
<summary>PVE 8 / Debian bookworm — one-liner <code>.list</code> format</summary>

```bash
echo "deb [signed-by=/etc/apt/keyrings/truenas-proxmox.gpg] \
https://thegrandwazoo.github.io/freenas-proxmox testing main" \
  | sudo tee /etc/apt/sources.list.d/truenas-proxmox.list
```

</details>

To switch back to stable, replace `Suites: testing` with `Suites: v3` in `truenas-proxmox.sources` (or `testing` with `v3` in `truenas-proxmox.list` if using the one-liner format) and run `apt update`.

---

## Configuration

After installation, **refresh your browser** to load the updated Proxmox UI. Then add a new storage:

1. Navigate to **Datacenter → Storage → Add → TrueNAS (ZFS/iSCSI)**
2. Fill in the storage fields — see the table below

### Fields

| Field | Value |
|-------|-------|
| ID | A short name, e.g. `truenas-vms`. Cannot be changed later. |
| TrueNAS Host | IP or hostname of your TrueNAS server. Also used as the iSCSI portal address unless Portal IP is set separately. |
| API Key | Paste the TrueNAS API key you generated. Leave blank at creation time only if you plan to use a [keyfile](#securing-the-api-token-recommended-for-production) instead. |
| Pool / Dataset Path | The ZFS pool or dataset path where VM disks are created, e.g. `tank` or `tank/proxmox/vdisks`. |
| Sub-dataset | Optional — extra sub-path appended below Pool / Dataset Path. Leave blank in most cases. |
| Shared | Enabled (required for clusters). |
| Use SSL | Enabled (recommended). |
| Verify SSL Certificate | Disabled unless TrueNAS has a valid CA-signed certificate (most homelab setups use self-signed certs). |
| Portal IP | Optional — leave blank unless the TrueNAS management IP differs from the iSCSI data IP. |
| Target IQN | Optional — leave blank; auto-discovered from existing iSCSI targets. |

Authentication is **Bearer token only** — username/password auth was removed in v3.0. If you're still on v2.x, see [Migrating from v2.x](docs/migrating-from-v2.md).

### Securing the API Token (Recommended for Production)

By default the API token is stored in `/etc/pve/storage.cfg`, which is replicated in plaintext across all cluster nodes. For production deployments, move it into a private keyfile that only root can read and that is not replicated:

```bash
# Run on each Proxmox node — replace 'truenas-vms' with your actual storage ID
STORAGEID="truenas-vms"
KEYFILE="/etc/pve/priv/truenas-${STORAGEID}.key"

echo -n "your-api-token-here" > "$KEYFILE"
chmod 600 "$KEYFILE"
pvesm set "$STORAGEID" --truenas_api_key ""
```

The plugin checks `/etc/pve/priv/truenas-<storeid>.key` automatically; if it exists, it's used and `truenas_api_key` in `storage.cfg` is ignored. The keyfile must exist on **every Proxmox node** — `/etc/pve/priv/` is not replicated via pmxcfs, so copy it manually.

### ZFS Block Size

v3.0's storage panel has no blocksize field — newly created zvols inherit the **default volblocksize of the parent pool/dataset** on TrueNAS. If you need a specific block size (e.g. 16k on TrueNAS SCALE, which requires a 16k minimum), set it as the default on the pool or dataset in the TrueNAS UI before creating disks through the plugin; it does not need to be reconfigured in Proxmox.

> This section previously described a Proxmox-side **ZFS Blocksize** field — that field belongs to the legacy v2.x built-in "ZFS over iSCSI" storage type, not the v3 plugin. See [Migrating from v2.x](docs/migrating-from-v2.md) if you're still running v2.x.

---

## Upgrading

### v2.x → v2.x (patch / minor upgrade)

Standard apt upgrade — the package re-applies any patches needed after a Proxmox VE update automatically:

```bash
apt update && apt full-upgrade
```

### v2.x → v3.0 (migration)

v3.0 is a different storage plugin type (`PVE::Storage::Custom::TrueNAS`) and uses a different architecture (per-VM iSCSI targets, `iscsi://` paths). There is no in-place upgrade — disk data stays on TrueNAS and you move VM disks across using Proxmox's built-in **Move Disk** function.

> **Tested migration path (confirmed in lab):**
> Migrating live VM disks from a v2.x storage to a v3.0 storage via Move Disk was validated on Proxmox VE 8.4 with TrueNAS CORE 13.0-U6 and TrueNAS SCALE 24.10. VMs remained running throughout the migration.

#### Step-by-step

1. **Install v3.0** on all Proxmox nodes (see [Installation](#installation) — use the testing channel until v3.0 is stable-released).

2. **Add a new v3.0 storage** in Proxmox (*Datacenter → Storage → Add → TrueNAS (ZFS/iSCSI)*). Use the same TrueNAS pool as your existing v2.x storage. Give it a distinct ID (e.g. `truenas-v3`).

3. **For each VM**, move its disks from the v2.x storage to the new v3.0 storage:
   - Select the VM → **Hardware** tab
   - Select the disk → **Move Disk**
   - Choose the new v3.0 storage as the target
   - Check **Delete source** if you want the old zvol removed after the move

   Repeat for each disk (including EFI disk if present). VMs can remain running during Move Disk.

4. **Verify** the VM boots and its disks are accessible after migration.

5. **Remove the v2.x storage** from Proxmox once all VMs are migrated (*Datacenter → Storage → Remove*). The iSCSI targets and extents that belonged to the old storage will need to be cleaned up from TrueNAS manually if they were not auto-removed.

> **Note:** EFI disks (`efidisk0`) and data disks can be migrated with Move Disk. TPM state disks (`tpmstate0`) must stay on local-lvm or NFS — see the [TPM limitation](#v30-upcoming) in Prerequisites.

---

## Uninstalling

```bash
apt remove truenas-proxmox
```

This removes the plugin and reverses all patches, returning your Proxmox VE installation to its unmodified state. Any storage configurations using this plugin should be removed from Proxmox before uninstalling.

---

## Troubleshooting

### Understanding what this plugin does — and does not — do

Before reporting an issue, it helps to know which layer the error is coming from. This plugin is an **orchestrator**: it calls the TrueNAS REST API to provision resources (create zvols, iSCSI extents, and target mappings). It does not carry data. The actual disk I/O path — QEMU reading and writing blocks — runs directly between Proxmox and TrueNAS over iSCSI, with no involvement from this plugin.

There are three distinct layers where errors can appear:

**Layer 1 — Plugin (TrueNAS REST API)**

The plugin called the TrueNAS API and got an error, or the API was unreachable. These errors come from the plugin code. On v3.0, they appear in syslog/journalctl with a `TrueNASPlugin:` prefix (v2.x used `freenas-proxmox:`).

Common causes:
- Wrong API host IP or hostname
- HTTP vs HTTPS mismatch (toggle **Use SSL**)
- API token expired, revoked, or not entered correctly
- TrueNAS iSCSI service not running
- TrueNAS API service not reachable from the Proxmox node

Example log line (v3.0):
```
TrueNASPlugin: Unable to connect to the TrueNAS API at '192.168.1.10' using HTTPS (500)
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

Errors from PVE's own storage subsystem — pvedaemon, pvestatd, or storage.cfg parsing.

Common causes:
- `storage.cfg` syntax error or stale config keys (especially after migrating from v2.x — see [migration guide](docs/migrating-from-v2.md))
- `pvedaemon` or `pvestatd` service crashed

**Quick triage:**

| Symptom | Likely layer | First check |
|---------|-------------|-------------|
| Disk creation fails, API error in task log | Plugin (Layer 1) | API key, SSL setting, TrueNAS API reachable |
| Disk created on TrueNAS but Proxmox reports error | Plugin (Layer 1) | syslog for `truenas-proxmox:` lines |
| VM won't start, iSCSI session error | iSCSI/QEMU (Layer 2) | TrueNAS iSCSI service, initiator group ACL |
| Storage shows unavailable | Proxmox core (Layer 3) | `pvedaemon` service, storage.cfg |

---

### After install, "TrueNAS (ZFS/iSCSI)" is not visible in the Add Storage dropdown

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

> **Note:** TrueNAS SCALE 25.04 also deprecates the REST API used by this plugin (v2.x). Full removal is planned for SCALE 26.x. Plugin v3.0.0 will add WebSocket JSON-RPC 2.0 support. See [issue #243](https://github.com/TheGrandWazoo/truenas-proxmox/issues/243).

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

Please use the [GitHub issue tracker](https://github.com/TheGrandWazoo/truenas-proxmox/issues) and include the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md). Include relevant log lines from `syslog` (search for `FreeNAS::`).

---

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

For significant changes, open an issue first to discuss the approach.

---

## Support the Project

This plugin is built and maintained by one person. Sponsorship directly funds the hardware lab used to test every release against real Proxmox and TrueNAS nodes before it ships to you.

**[Become a sponsor on GitHub](https://github.com/sponsors/TheGrandWazoo)** — GitHub Sponsors has no platform fee and goes straight to development.

Sponsor tiers:
- **$5/month** — Supporter. You keep this maintained.
- **$10/month** — Backer. Listed in DONORS.md.
- **$25/month** — Sustainer. Priority issue responses.

Donor support has funded a 4-node Proxmox cluster and TrueNAS test lab used for development and validation. See [DONORS.md](DONORS.md) for a full list of donors.

---

## License

Copyright (c) 2020 KSA Technologies, LLC

This program is free software: you can redistribute it and/or modify it under the terms of the [GNU Affero General Public License](LICENSE) as published by the Free Software Foundation, version 3.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
