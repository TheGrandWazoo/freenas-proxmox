# Upgrade Paths

Quick reference for every migration scenario. Find your current version and repo source in the table, then follow the link for step-by-step instructions.

---

## Where am I, and where do I go?

| Current version | Current repo | → Stay on current major | → Move to v3.x | → Move to v4.x |
|---|---|---|---|---|
| **v2.x** | Cloudsmith stable | [Swap repo to GitHub Pages `main`](#cloudsmith-to-github-pages) | [Swap repo + config migration](migrating-from-v2.md) | [v2→v3 config migration first, then v3→v4](#v2-to-v4) |
| **v2.x** | GitHub Pages `main` | Already on correct repo ✅ | [Config migration only](migrating-from-v2.md) | [v2→v3 config migration first, then v3→v4](#v2-to-v4) |
| **v3.x** | Cloudsmith stable | [Swap repo to GitHub Pages `v3`](#cloudsmith-to-github-pages) | Already on v3 — swap repo only | [Swap repo straight to the `v4` track](#v3-to-v4) |
| **v3.x** | GitHub Pages `v3` | Already on correct repo ✅ | Already here ✅ | [Change dist track to `v4`](#v3-to-v4) |
| **v4.x** | GitHub Pages `v4` | Already on correct repo ✅ | — | Already here ✅ |

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
4. Add the GitHub Pages source pointing at the right dist track (`main` for v2, `v3` for v3, `v4` for v4). A v3 Cloudsmith user can go directly to `v4`. Follow [v3.x → v4.x](#v3-to-v4) from step 2 onwards.
5. Run `apt update`

---

## What changes between major versions

| | v2.x → v3.x | v3.x → v4.x |
|---|---|---|
| **Breaking change?** | Yes — auth model, iSCSI model, package name | Platform only: requires **PVE 9**. Adds a WebSocket transport, used automatically for SCALE 25.04+. CORE and SCALE < 25.04 stay on REST |
| **In-place upgrade?** | No — VM disks must be moved | **Yes** — switch the dist track, then `apt upgrade` |
| **Plugin restarts VMs?** | No — Move Disk is live | **No**. Only the PVE daemons restart (`pvedaemon`, `pveproxy`, `pvestatd`, `pve-ha-lrm`, `pve-ha-crm`). Running VMs keep their iSCSI connections |
| **Config changes?** | Yes — API key replaces username/password | **None**. `storage.cfg` is read unchanged |
| **Full guide** | [migrating-from-v2.md](migrating-from-v2.md) | [v3.x → v4.x](#v3-to-v4) below |

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

## v3.x → v4.x {#v3-to-v4}

v4.0 adds a WebSocket JSON-RPC 2.0 transport for TrueNAS SCALE 25.04 and later. SCALE 25.04 deprecated the REST API, and SCALE 26.x is planned to remove it. The plugin detects the transport **per TrueNAS host** each time the daemons start:

| TrueNAS host | Transport used by v4 |
|---|---|
| CORE 13.x | REST v2.0 (unchanged from v3) |
| SCALE < 25.04 (e.g. 24.10) | REST v2.0 (unchanged from v3) |
| SCALE 25.04 and later | WebSocket JSON-RPC 2.0 |

You choose nothing and configure nothing. A cluster can mix CORE and SCALE hosts, and each storage uses whichever transport its host needs. To see which one was picked:

```bash
journalctl -b | grep -o '[^ ]*: detected version=.*' | sort -u
# 172.31.69.90: detected version=TrueNAS-13.0-U6.8 -> rest transport
# 172.31.69.91: detected version=TrueNAS-25.10.6 -> ws transport
```

The upgrade is an **in-place `apt upgrade`**. VM disks are not moved and running VMs are not restarted.

### 1. Pre-upgrade checks (every node)

- **PVE 9 is required.** The v4 package installs on PVE 8 without complaint, but PVE 8 refuses to load the plugin (storage API 15 > 11) and every TrueNAS storage on that node goes inactive. Upgrade the node to PVE 9 first (`pve8to9 --full`). Until then, keep PVE 8 nodes on **3.0.0-1**, the last release with storage API 11. Pin it with `apt install truenas-proxmox=3.0.0-1 && apt-mark hold truenas-proxmox`. Every v3.1+ release also needs PVE 9. The v3 and v4 plugins read the same `storage.cfg`, so a cluster can run both while you upgrade it node by node.
- **No v2 storages left.** v2 storages use the `zfs:` type with `iscsiprovider freenas` and are not managed by v3 or v4. If this prints anything, finish the [v2→v3 migration](migrating-from-v2.md) for those disks first:
  ```bash
  grep -B1 -A8 'iscsiprovider freenas' /etc/pve/storage.cfg
  ```
- **Note any orphan volumes.** Volumes left behind by plugin versions ≤ 4.0.1 (see the README troubleshooting entries for [#291](https://github.com/TheGrandWazoo/freenas-proxmox/issues/291) and [#292](https://github.com/TheGrandWazoo/freenas-proxmox/issues/292)) do not block the upgrade. On v4.0.2+ you can delete them normally with `pvesm free`. Lists disks that no VM config references:
  ```bash
  for s in $(awk '/^truenas(-multipath)?:/{print $2}' /etc/pve/storage.cfg); do
    pvesm list "$s" | awk 'NR>1{print $1}' | while read -r v; do
      grep -rqs -- "${v#*:}" /etc/pve/nodes/*/qemu-server/ || echo "unreferenced: $v"
    done
  done
  ```
- **Check the API key.** v4 reads the same `truenas_api_key` in `storage.cfg`, or `/etc/pve/priv/truenas-<storeid>.key` if that file exists (supported since v3.0). If a SCALE host was upgraded to 25.04, make sure its key wasn't revoked. See the README entry *API key stops working after upgrading TrueNAS SCALE to 25.04*.

### 2. Switch the dist track to `v4` (every node)

If you use the multipath package, keep `multipath` in `Components`. Each dist track has its own `multipath` component, so it moves with the base package.

```bash
# deb822 format (PVE 9 / Debian trixie)
cat << 'SOURCES' | sudo tee /etc/apt/sources.list.d/truenas-proxmox.sources
Types: deb
URIs: https://thegrandwazoo.github.io/freenas-proxmox
Suites: v4
Components: main
Signed-By: /etc/apt/keyrings/truenas-proxmox.gpg
SOURCES
# Multipath users: use "Components: main multipath" above instead.

# Remove any leftover one-line source for the v3 track, so apt doesn't see both
sudo rm -f /etc/apt/sources.list.d/truenas-proxmox.list
```

<details>
<summary>One-line <code>.list</code> format (if you prefer it over deb822)</summary>

```bash
echo "deb [signed-by=/etc/apt/keyrings/truenas-proxmox.gpg] \
https://thegrandwazoo.github.io/freenas-proxmox v4 main" \
  | sudo tee /etc/apt/sources.list.d/truenas-proxmox.list
# Multipath users: end the line with "v4 main multipath" instead.
```

</details>

The codename `rivendell` works in place of `v4`.

### 3. Upgrade (every node)

```bash
sudo apt update && sudo apt upgrade
dpkg -l truenas-proxmox truenas-proxmox-multipath 2>/dev/null | grep '^ii'   # expect 4.x
```

apt installs two new dependencies, `libprotocol-websocket-perl` and `libio-socket-ssl-perl`. The package `postinst` then restarts `pvedaemon`, `pveproxy`, `pvestatd`, `pve-ha-lrm` and `pve-ha-crm`. Running VMs are untouched, because QEMU holds its own iSCSI connection.

### 4. Verify

```bash
pvesm status | grep -E 'truenas'          # every TrueNAS storage should be "active"
journalctl -b | grep -o '[^ ]*: detected version=.*' | sort -u   # one line per TrueNAS host
```

Then create a small test disk and remove it on each storage. The Proxmox UI works, or you can use `pvesm alloc <storage> <vmid> vm-<vmid>-disk-9 1G` followed by `pvesm free <storage>:vm-<vmid>-disk-9`.

**Rollback:** set the dist track back to `v3` and run `apt update`. Then downgrade to the version shown by `apt-cache policy truenas-proxmox`, e.g. `apt install truenas-proxmox=3.2.5-1`. If you use multipath, add `truenas-proxmox-multipath=3.2.5-1` to the same command. Neither `storage.cfg` nor TrueNAS needs any change.

`apt upgrade` on the `v3` dist track never pulls in a v4 package. You must change the dist track explicitly. This is intentional.

---

## v2.x → v4.x {#v2-to-v4}

There is no direct path from v2 to v4. v2 uses the stock Proxmox `zfs:` storage type with patched core files. v3 and v4 use a different storage type and auth model, and VM disks have to be moved onto it. In order:

1. Follow [migrating-from-v2.md](migrating-from-v2.md) to install the plugin, add a `truenas:` storage, and **Move Disk** every VM off the v2 storage. Install from the `v4` track directly if the node is already on PVE 9. The new-storage and Move Disk steps are the same. If the node is still on PVE 8, install from `v3` pinned to 3.0.0-1 (`apt install truenas-proxmox=3.0.0-1 && apt-mark hold truenas-proxmox`).
2. Remove the old `zfs:` / `iscsiprovider freenas` storage entries and purge `freenas-proxmox`.
3. If you installed from `v3`, upgrade the node to PVE 9, then follow [v3.x → v4.x](#v3-to-v4).

---

## Dist track reference

| Dist track | Codename alias | Contains | Who should use it |
|---|---|---|---|
| `main` | `limelight` | v2.x packages only | Users staying on v2.x |
| `v2` | `limelight` | v2.x packages (alias for `main`) | Same as `main` — explicit pin |
| `v3` | `error` | v3.x packages only | All current v3 installs |
| `v4` | `rivendell` | v4.x packages only | All new installs and PVE 9 clusters (current stable) |

Both the dist track (`v3`) and its codename alias (`error`) work in `sources.list` — they resolve to the same packages.

Packages on one dist track are never promoted to another. Changing major versions always requires an explicit `sources.list` edit.

> **Existing v3 users — one-time prompt after v3.2.2**
> If `apt update` reports `changed its 'Codename' value from 'v3' to 'error'`, run:
> ```bash
> apt update --allow-releaseinfo-change
> ```
> This is a one-time acknowledgment of the codename being added in v3.2.2. It will not recur.
