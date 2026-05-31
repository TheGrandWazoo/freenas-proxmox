# Migrating from v2.x to v3.0

This guide covers moving from the old `freenas-proxmox` v2.x plugin to the new `truenas-proxmox` v3.0 plugin.

v3.0 is a clean break from v2.x — a completely rewritten native Proxmox storage plugin. You cannot upgrade in place. The migration involves installing the new plugin, adding a new storage entry, and moving your VM disks across using Proxmox's built-in Move Disk function. **VMs can stay running throughout.**

---

## What's a zvol?

A **zvol** (ZFS volume) is TrueNAS's name for a dedicated chunk of storage carved out of a pool — think of it as a virtual hard drive sitting inside TrueNAS. Each VM disk in this plugin is its own zvol. When you "move a disk," Proxmox creates a new zvol, copies the data to it, and deletes the old one.

---

## What changed from v2.x

**Authentication:** v2.x used a username and password (or a secret token). v3.0 uses a TrueNAS API key only — username/password is gone.

**iSCSI connection model:** v2.x ran `iscsiadm` on the Proxmox host to create kernel iSCSI sessions. You could see block devices like `/dev/disk/by-path/ip-...` on your Proxmox node. In v3.0, QEMU connects directly to TrueNAS via `iscsi://` — no kernel sessions, no block devices on the host. **This is expected and correct.** If you look in `/dev/` and don't see the disk, that's fine — QEMU holds the connection, not the host.

**Per-VM targets:** v2.x shared iSCSI targets across VMs. v3.0 creates a dedicated iSCSI target for each VM (`proxmox-vm-<vmid>`). This means removing one disk never affects other VMs.

**Package name:** `freenas-proxmox` is now a transitional stub that installs `truenas-proxmox`. Both can coexist during migration.

---

## Pre-migration checklist

Do these checks **before** you start:

```
[ ] All Proxmox nodes running PVE 8.0 or newer
      pveversion | grep pve-manager

[ ] TrueNAS reachable from each Proxmox node (API + iSCSI)
      curl -k https://<truenas_host>/api/v2.0/system/info
      nc -zv <truenas_host> 3260

[ ] iSCSI service enabled on TrueNAS
      Sharing → iSCSI → Target Global Configuration: check "Enable"

[ ] TrueNAS pool is healthy (no resilvering, no scrub running)
      TrueNAS → Storage → Pools: all pools show "Healthy"

[ ] TrueNAS pool has free space ≥ your largest single disk
      (only one copy is needed at a time if you move one disk at a time)

[ ] Check each VM for tpmstate0 disks (see TPM section below)
      Proxmox → VM → Hardware: look for tpmstate0

[ ] Back up any VMs you're not comfortable losing (optional but recommended)
```

**Ports required from Proxmox to TrueNAS:**

| Port | Protocol | Used for |
|------|----------|---------|
| 443  | HTTPS    | Plugin API calls (REST v2.0) |
| 3260 | TCP      | iSCSI disk I/O (QEMU to TrueNAS) |
| 22   | SSH      | Not needed — removed in v3.0 |

---

## Check for TPM state disks first

Before you do anything else, check if any of your VMs have a TPM state disk. QEMU requires TPM state on a local filesystem path — it cannot use `iscsi://` URIs. You cannot migrate `tpmstate0` to v3.0 iSCSI storage.

**How to check:** In Proxmox, click each VM → **Hardware** tab. Look for a disk labeled `tpmstate0`. If you see one, you need to move it to `local-lvm` or NFS storage **before** migrating that VM's other disks.

> **Note for HA users:** If the VM is managed by Proxmox HA, `local-lvm` is not suitable for `tpmstate0` (it won't be accessible on other nodes if the VM is restarted). Use NFS or another shared filesystem storage for `tpmstate0` instead.

---

## Step 1 — Install v3.0 on every Proxmox node

Run this on **every node in the cluster** before adding the new storage:

```bash
# Add the Cloudsmith repo (if not already added)
curl -1sLf 'https://dl.cloudsmith.io/public/ksatechnologies/truenas-proxmox/setup.deb.sh' | bash

# Install
apt update && apt install truenas-proxmox
```

Verify the install on each node:
```bash
dpkg -l truenas-proxmox
```

---

## Step 2 — Create an API key on TrueNAS

**TrueNAS SCALE:**
1. Log in to the TrueNAS web UI
2. Go to **System Settings → API Keys**
3. Click **Add**, give it a name (e.g. `proxmox-v3`), click **Generate Key**
4. Copy the key — you will only see it once

**TrueNAS CORE:**
1. Log in to the TrueNAS web UI
2. Click the gear icon (top right) → **API Keys**
3. Click **Add**, give it a name, click **Submit**
4. Copy the key

Keep the key somewhere safe — you will paste it into Proxmox next.

---

## Step 3 — Add the v3.0 storage in Proxmox

> Keep your existing v2.x storage entry active — **do not remove it yet**. Both entries can coexist while you migrate.

1. In the Proxmox web UI, go to **Datacenter → Storage → Add → TrueNAS**
2. Fill in the fields:

   | Field | What to enter |
   |-------|--------------|
   | ID | A new name, e.g. `truenas-v3` — must be different from your v2 storage ID |
   | TrueNAS Host | Same IP/hostname as your v2 storage |
   | API Key | The key you just created |
   | Pool | Same ZFS pool path as before (e.g. `tank/proxmox/disks`) |
   | Nodes | Select all cluster nodes |

3. Click **Add**. If the storage turns green and shows free/used space, you are connected.

**What is "Portal IP"?** Leave it blank for a typical setup with one TrueNAS box on one network. Only fill this in if your TrueNAS has separate management and iSCSI data network interfaces and you want iSCSI traffic on a specific IP.

---

## Step 4 — Move your VM disks

For each VM disk, use Proxmox's Move Disk function. VMs can stay powered on. Each move copies the disk data, then cuts over — you may notice a brief I/O pause (typically under a second) at the moment of cutover. For database or latency-sensitive workloads, consider scheduling moves during low-traffic windows.

1. Click the VM → **Hardware** tab
2. Click a disk (e.g. `scsi0`) → **Move Disk** in the top toolbar
3. Set **Target Storage** to `truenas-v3`
4. **Delete source:** if checked, Proxmox will automatically delete the old zvol immediately after the copy finishes and the VM switches to the new disk. If unchecked, both zvols remain — you can delete the old one manually from TrueNAS later. When in doubt, leave unchecked and delete manually after verifying the VM works.
5. Click **Move Disk** and wait for the task to complete before starting the next move

**Capacity note:** Each move requires free pool space equal to the size of the disk being moved. If you move one disk at a time and check "Delete source," you only need space for one disk. If you run moves in parallel, multiply accordingly.

**Timing:** A 100 GB disk over a 1 Gbps link takes roughly 10–15 minutes. Plan accordingly for large disks.

Repeat for every disk on every VM. EFI disks, CloudInit drives, and data disks all follow the same process. Skip `tpmstate0` disks — handle those separately as described above.

---

## Step 5 — Verify and clean up

After moving all disks for a VM:

1. **Check the Hardware tab** — all disks should reference `truenas-v3`
2. **Restart the VM** (or stop/start) and confirm it boots normally
3. **Check TrueNAS** — go to Sharing → iSCSI → Targets. You should see one target named `proxmox-vm-<vmid>` for each migrated VM, with the correct number of LUNs

Once all VMs are migrated:

1. Confirm no disks reference the old v2.x storage: run this on any Proxmox node and expect no output:
   ```bash
   grep -r 'old-storage-id:' /etc/pve/nodes/*/qemu-server/ /etc/pve/nodes/*/lxc/ 2>/dev/null
   ```
   *(Replace `old-storage-id` with your actual v2 storage ID)*

2. Go to **Datacenter → Storage**, select the old v2.x storage, click **Remove**

3. Clean up any leftover iSCSI extents or targets on TrueNAS that were not auto-removed (see [migration-troubleshooting.md](migration-troubleshooting.md))

---

## Frequently asked questions

**Can I run v2.x and v3.0 at the same time?**
Yes — both storage entries coexist in Proxmox during migration. Remove the v2.x entry only after all disks are moved.

**What if something goes wrong — can I go back?**
Yes. The original disk is not deleted until the move fully completes (and only if you checked "Delete source"). If a move fails, the VM is still running on its original disk. You can also move disks back from v3.0 to v2.x storage using the same Move Disk process in reverse.

**Will my VMs have downtime?**
No shutdown required. Move Disk with a running VM uses live storage migration. Expect a brief I/O pause (typically under a second) at cutover.

**What happened to my block devices in `/dev/`?**
In v3.0, QEMU talks to iSCSI directly — no kernel sessions are created, so no block devices appear on the Proxmox host. This is correct behavior. Tools like `iscsiadm` and `lsscsi` will not show your VM disks.

**What about snapshots on my old disks?**
Proxmox-level snapshots taken via the v2.x plugin will not transfer. If you have important snapshot data, revert to a snapshot before migrating. ZFS-level snapshots on TrueNAS are unaffected.

**My old storage still shows orphaned extents on TrueNAS after removal.**
See [Dangling resources after removal](migration-troubleshooting.md#dangling-resources-after-removal) in the troubleshooting guide.
