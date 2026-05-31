# Migration Advanced Reference: v2.x to v3.0

This document is for administrators who want a full understanding of what changes between v2.x and v3.0, how to plan large-scale migrations, and how to handle edge cases. For a step-by-step walkthrough, start with the [Migration Guide](migrating-from-v2.md).

---

## What changed architecturally

### v2.x: Host-managed iSCSI sessions

v2.x used `iscsiadm` on the Proxmox host to establish kernel-level iSCSI sessions. All VMs on a storage shared a small number of iSCSI targets, with each VM disk assigned to a different LUN number. Device nodes like `/dev/disk/by-path/ip-...-lun-0` appeared on the Proxmox host and were passed to QEMU as block devices.

**Consequences:**
- iSCSI sessions visible on the host (`iscsiadm -m session`)
- Block device nodes in `/dev/` on the Proxmox host
- LUN limit per target (256 max)
- Removing one disk from a running VM could disrupt other VMs on the same target
- Depended on SSH keys from Proxmox nodes to TrueNAS for pool enumeration

### v3.0: Per-VM targets, QEMU-native iSCSI

v3.0 creates a dedicated iSCSI target for each VM (`proxmox-vm-<vmid>`) and passes an `iscsi://` URI directly to QEMU. QEMU's built-in libiscsi library opens the session — no kernel iSCSI daemon involved.

**Consequences:**
- No iSCSI sessions visible on the Proxmox host
- No block device nodes in `/dev/` — this is expected and correct
- Each VM has exactly one target; all its disks are LUNs on that target
- Removing a disk from one VM never affects another VM's connection
- No SSH keys required — the plugin communicates only via TrueNAS REST API

The `iscsi://` URI format stored in the VM config:
```
iscsi://<portal_ip>/<iqn>:<target_name>/<lun_id>
```
Example:
```
iscsi://192.168.10.50/iqn.2005-10.org.freenas.ctl:proxmox-vm-100/0
```

---

## Configuration field mapping

| v2.x field | v3.0 field | Notes |
|-----------|-----------|-------|
| `type freenas` / `iscsiprovider freenas` | `type truenas` | New storage plugin type |
| `freenas_user` | *(removed)* | Basic auth no longer supported |
| `freenas_password` | *(removed)* | Basic auth no longer supported |
| `truenas_secret` | `truenas_api_key` | Same concept; renamed |
| `portal` | `truenas_portal_ip` | Optional; defaults to `truenas_host` |
| `target` | `truenas_target` | Optional; base IQN for auto-discovery |
| `pool` | `truenas_pool` | Same ZFS pool path |
| — | `truenas_dataset` | New: optional sub-dataset within the pool |
| `truenas_ssl` | `truenas_ssl` | Unchanged (default: 1) |
| `truenas_ssl_verify` | `truenas_ssl_verify` | Unchanged (default: 0) |

A v2.x storage config block like:
```
freenas: old-storage
    freenas_user admin
    freenas_password secret
    portal 192.168.10.50
    pool tank/proxmox/disks
    truenas_ssl 1
    truenas_ssl_verify 0
```

Becomes in v3.0:
```
truenas: truenas-v3
    truenas_host 192.168.10.50
    truenas_api_key 1-AbCdEf...
    truenas_pool tank/proxmox/disks
    truenas_ssl 1
    truenas_ssl_verify 0
    nodes pve01,pve02,pve03
    shared 1
```

---

## HA (High Availability) considerations

If any VM is managed by Proxmox HA, disable HA for that VM before migrating its disks:

1. Datacenter → HA → Resources → select the VM → Remove (or set to disabled)
2. Migrate the disks
3. Re-enable HA after migration is complete

If a node fences (reboots unexpectedly) while Move Disk is in progress, the HA manager may attempt to restart the VM on another node. The VM config may still reference the old disk at that point. Check the VM config after recovery and re-run the migration if needed. The original disk is always preserved until Move Disk fully completes.

---

## Single portal — single point of failure

v3.0 does not support iSCSI multipath. QEMU's libiscsi opens one connection to the portal IP and retries on failure but does not fail over to a second IP.

If your TrueNAS has multiple network interfaces or portal IPs, `truenas_portal_ip` selects exactly one. **All Proxmox nodes must be able to reach that IP on port 3260.** A failure of that interface will cause all VMs on that storage to lose disk access.

Options for resilience:
- Use a floating/virtual IP at the network layer (bond, VRRP/CARP)
- Ensure the portal IP is on a highly available network segment
- Multipath support is tracked for a future release

---

## Running v2.x and v3.0 in parallel

Both storage entries can coexist in `/etc/pve/storage.cfg`. Proxmox routes disk allocation to whichever storage is specified — the two plugins do not interfere with each other. This allows a rolling, VM-by-VM migration without any maintenance window.

Recommended approach for clusters with many VMs:
1. Install v3.0 on all nodes first (required before adding the new storage type)
2. Add the v3.0 storage entry
3. Migrate VMs in batches — test one or two first before proceeding
4. Remove the v2.x storage entry only after confirming the last VM is migrated

---

## Planning for large deployments

**Capacity:** Move Disk creates a full copy of the zvol before deleting the old one. You need free pool space equal to the size of one disk at a time (or however many moves run concurrently). If free space is tight, migrate and verify one disk at a time with "Delete source" checked before starting the next.

**Concurrency:** Proxmox allows multiple Move Disk operations in parallel, but each operation is I/O-intensive. Limit concurrency to 2–3 simultaneous moves and **stagger start times by 5–10 minutes** — if multiple moves reach the cutover phase at the same time, multiple VMs will see simultaneous I/O pauses. Monitor TrueNAS pool load during migrations: `zpool iostat 1`. If the pool is above 60–70% utilization, reduce concurrency.

**Network:** Move Disk transfers data through the Proxmox host, not directly on TrueNAS. Traffic path: TrueNAS → iSCSI → Proxmox host RAM → iSCSI → TrueNAS. For a 1 Gbps link, budget ~10–15 minutes per 100 GB.

**Verification checklist per VM:**

- [ ] All disks listed in Hardware tab reference the new storage
- [ ] VM boots cleanly from the new storage
- [ ] `qm config <vmid>` shows no references to the old storage ID
- [ ] TrueNAS: one iSCSI target named `proxmox-vm-<vmid>` exists with the correct number of LUNs
- [ ] TrueNAS: old zvols from v2.x storage are gone (if Delete source was checked)

**Verification for the whole cluster when done:**

```bash
# Find any VM configs still referencing the old storage ID (replace 'old-storage' with your v2 ID)
grep -r 'old-storage:' /etc/pve/nodes/*/qemu-server/ /etc/pve/nodes/*/lxc/ 2>/dev/null
```

No output means all disks are migrated.

---

## Why there is no in-place rename path

An in-place rename would require:
1. Renaming each zvol on TrueNAS to match the new naming convention
2. Rebuilding the iSCSI extent, target, and target-extent association under v3.0's per-VM model
3. Rewriting the disk path in the Proxmox VM config from a block device to an `iscsi://` URI

Steps 2 and 3 require the VM to be offline and involve several API calls that can fail partway through. The Move Disk path is safer because Proxmox manages the cutover atomically and the VM can stay running. An offline rename script may be provided in a future release for large deployments where copying data is impractical.

---

## Rollback

If a Move Disk operation fails partway through:

1. The original disk is untouched — it is not deleted until the move completes successfully and you confirm
2. The new (partial) zvol and any iSCSI objects created on TrueNAS may be left behind — clean these up manually:
   - On TrueNAS: **Sharing → iSCSI → Extents** — delete the orphaned extent
   - On TrueNAS: **Sharing → iSCSI → Targets** — delete the orphaned target (if no other disks for that VM exist)
   - On TrueNAS: **Storage → Pools → Browse** — delete the orphaned zvol
3. The VM's config in Proxmox still references the original disk — it is unaffected

If you decide to roll back entirely to v2.x after partially migrating:
- Disks still on v2.x storage will continue to work on v2.x
- Disks already moved to v3.0 storage must stay on v3.0 storage — moving back is the same Move Disk process in reverse

---

## TPM state disks

VMs with vTPM enabled have a `tpmstate0` disk. QEMU requires this to be a local filesystem path — the `iscsi://` URI model that v3.0 uses is incompatible.

**If your v2.x storage used the kernel iSCSI path model (block device), tpmstate0 may have worked there.** In v3.0 it will not. Before migrating a VM with TPM:

1. Move the `tpmstate0` disk to `local-lvm` or NFS storage first
2. Then migrate the remaining disks to v3.0 storage as normal

For live VM migration across cluster nodes (if needed), the `tpmstate0` disk must also be on shared filesystem storage (NFS, CephFS) — local-lvm does not support live migration.

---

## API key security

v2.x stored credentials in `/etc/pve/storage.cfg` in plain text. v3.0 supports the same (`truenas_api_key` in the config file), but also supports keyfiles stored outside the cluster config:

```bash
# Store on each node (not synced across the cluster)
mkdir -p /etc/pve/priv/truenas
echo "1-YourKeyHere" > /etc/pve/priv/truenas/truenas-v3.key
chmod 600 /etc/pve/priv/truenas/truenas-v3.key
```

The plugin looks for `/etc/pve/priv/truenas/<storeid>.key` and prefers it over the config file value. This keeps the API key out of the cluster config database (which is readable by all cluster members).

---

## Cluster node considerations

The storage config in `/etc/pve/storage.cfg` is cluster-wide. The plugin must be installed on every node that has the storage in its `nodes` list. If a node is missing the plugin, `pvesm status` will show an error for that storage on that node.

Install order:
1. Install `truenas-proxmox` on all nodes first
2. Then add the storage entry (or it may fail on nodes that don't have the plugin yet)

The API key and any keyfiles must be present on every node individually — keyfiles in `/etc/pve/priv/` are not synced across the cluster.
