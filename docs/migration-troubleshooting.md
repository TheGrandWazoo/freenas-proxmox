# Migration Troubleshooting

This guide covers problems specific to migrating from v2.x to v3.0. For general post-migration errors, see the troubleshooting section in the [README](../README.md).

---

## Move Disk fails immediately

**Symptom:** Task errors within seconds of starting Move Disk.

**Check the task log** (click the failed task in Proxmox):

| Error | Cause | Fix |
|-------|-------|-----|
| `TrueNAS API token not configured` | API key missing from the v3.0 storage config | Edit the storage in Datacenter → Storage and add the API key |
| `Pool dataset '...' not found` | `truenas_pool` path doesn't exist on TrueNAS | Verify the pool path in the storage config matches exactly what TrueNAS shows |
| `422 Unprocessable Entity` | API field validation error | Check TrueNAS version compatibility; enable logging (`journalctl -u pvedaemon -f`) for detail |
| `SSL: certificate verify failed` | `truenas_ssl_verify 1` but certificate is self-signed | Set `truenas_ssl_verify 0` in storage config, or install a valid certificate |
| `Connection refused` | Wrong host/IP or TrueNAS API not reachable | Verify host from the Proxmox node: `curl -k https://<host>/api/v2.0/system/info` |

---

## Move Disk hangs or times out

**Symptom:** Task starts, progress bar moves, but eventually fails with a timeout or connection error.

- **Network interruption:** iSCSI traffic is sensitive to packet loss. Check switch/VLAN configuration between Proxmox and TrueNAS.
- **TrueNAS pool under stress:** If the pool is rebuilding (resilver in progress) or highly loaded, I/O will be slow. Check TrueNAS → Storage → Pools for any active operations.
- **Large disk:** A 500 GB disk at 1 Gbps takes ~70 minutes. Proxmox's default task timeout may trigger. Check if the task actually completed on TrueNAS despite the Proxmox error.

After a failed move, check TrueNAS for a partial zvol:
```
Sharing → iSCSI → Extents    # look for an extent with the new disk name
Storage → Pools → Browse     # look for a partial zvol
```
Delete any partial resources before retrying.

---

## VM won't start after Move Disk

**Symptom:** VM was running before migration, fails to start after the disk move completes.

**Check the VM config:**
```bash
qm config <vmid>
```
Look for the moved disk's line. It should show `iscsi://...` as the path, not a block device path.

**Check the iSCSI target exists on TrueNAS:**
1. TrueNAS → Sharing → iSCSI → Targets — confirm `proxmox-vm-<vmid>` is present
2. TrueNAS → Sharing → iSCSI → Extents — confirm the extent for each disk is present
3. TrueNAS → Sharing → iSCSI → Associated Targets — confirm each extent is linked to the target at the correct LUN

If any of these are missing, the disk cannot be accessed. Re-run a Move Disk operation to recreate the iSCSI objects, or use the Proxmox task log to identify which step failed.

**Check the iSCSI portal is reachable:**
```bash
# From the Proxmox node, using qm's built-in check:
qm start <vmid>
# Read the full error in the task log — it often includes the iscsi:// URI
```

If the error is `Failed to open drive ... iscsi://...`: the QEMU process cannot reach the iSCSI portal. Check:
- `truenas_portal_ip` in storage config — should be the IP that Proxmox can reach TrueNAS on
- Firewall rules between Proxmox and TrueNAS on port 3260
- iSCSI service is running on TrueNAS (Sharing → iSCSI → Target Global Configuration → Enable)

---

## Disk shows wrong size or "undefined" after move

**Symptom:** The disk appears in the Hardware tab but shows "undefined" or an incorrect size.

This is usually transient — the Proxmox UI polls before the iSCSI setup is fully complete. Wait 30–60 seconds and refresh.

If it persists:

1. Check `volume_size_info` is returning a value:
   ```bash
   pvesm volume_info <storeid> <volid>
   ```
   Example: `pvesm volume_info truenas-v3 truenas-v3:vm-100-disk-0`

2. If this returns an error, the plugin cannot find the zvol via the TrueNAS API. Verify the zvol exists:
   ```bash
   curl -sk -H "Authorization: Bearer <apikey>" \
     https://<truenas_host>/api/v2.0/pool/dataset/id/<pool>%2F<volname>
   ```

3. If the zvol exists but `volume_size_info` fails, check for SSL or API connectivity issues in the daemon log:
   ```bash
   journalctl -u pvedaemon --since '5 minutes ago' | grep TrueNAS
   ```

---

## Dangling resources after removal

**Symptom:** After removing the v2.x storage from Proxmox, TrueNAS still has old iSCSI extents, targets, or zvols that weren't cleaned up.

The v2.x plugin may not have removed these automatically. They are harmless but waste space and clutter the iSCSI config.

**To clean up manually on TrueNAS:**

1. **Extents** (Sharing → iSCSI → Extents): Delete any extents whose name matches old VM disk names
2. **Target-Extent associations** (Sharing → iSCSI → Associated Targets): Delete associations for removed targets
3. **Targets** (Sharing → iSCSI → Targets): Delete targets that no longer have any Proxmox VMs using them
4. **Zvols** (Storage → Pools → Browse): Delete zvols that were not cleaned up (confirm the VM config no longer references them first)

Always verify a zvol is truly unused before deleting it — check `qm config` for all VMs.

---

## Old v2.x storage can't be removed from Proxmox

**Symptom:** "Remove" is greyed out or fails with "storage is still in use."

Proxmox blocks storage removal if any VM config still references it. Find the VMs:
```bash
grep -r 'old-storage:' /etc/pve/nodes/*/qemu-server/ /etc/pve/nodes/*/lxc/ 2>/dev/null
```

For each match, move or remove the disk first. Common leftovers:
- **Unused disks** (detached but not deleted): VM → Hardware tab, look for `unused0`, `unused1` etc. referencing the old storage
- **CloudInit drives**: Move or delete the CloudInit drive (it will be regenerated)
- **EFI disks**: Move via Move Disk the same as any other disk

---

## iSCSI service stops working after migration

**Symptom:** VMs that were running fine start failing with iSCSI errors after migration.

This is not a migration problem — it means the iSCSI service on TrueNAS is unhealthy. Check:

1. **TrueNAS → Sharing → iSCSI** — confirm the service shows as running
2. **TrueNAS System Logs** — look for any iSCSI service errors around the time of failure
3. **Proxmox node logs:**
   ```bash
   dmesg | grep -i iscsi
   journalctl -u pvedaemon --since '30 minutes ago' | grep TrueNAS
   ```

If TrueNAS rebooted or the iSCSI service was restarted, running VMs with iSCSI disks will lose connectivity. QEMU will retry the connection — VMs typically recover within 30–60 seconds if the service comes back quickly. For production workloads, configure TrueNAS to start the iSCSI service automatically on boot.

---

## Move Disk failure recovery matrix

If a Move Disk operation fails partway through, use this table to determine what to clean up and whether it is safe to retry:

| What failed | State on TrueNAS | VM state | Action |
|-------------|-----------------|----------|--------|
| Zvol copy (mid-copy) | Partial zvol exists | Running on original disk | Delete partial zvol on TrueNAS, retry Move Disk |
| iSCSI extent creation | New zvol exists, no extent | Running on original disk | Delete new zvol on TrueNAS, retry Move Disk |
| iSCSI target creation | New zvol + extent exist | Running on original disk | Delete extent and new zvol, retry Move Disk |
| targetextent association | All iSCSI objects exist | Running on original disk | Delete targetextent, extent, new zvol, retry Move Disk |
| VM config rewrite | All iSCSI objects exist, config not updated | Running on original disk | Verify VM is still on old disk (`qm config`); delete new iSCSI objects and zvol, retry |
| Zvol deletion (Delete source) | New disk active, old zvol still present | Running on new disk | Verify VM config references new disk; delete old zvol manually with `zfs destroy` |
| Node crash mid-copy | Partial zvol may exist | Will recover to original disk | After node recovers, check TrueNAS for partial zvol; delete if found; retry Move Disk |

The original disk is never modified or deleted during the copy phase. If anything fails before the VM config is rewritten, the VM will continue running on its original disk.

---

## API key revoked or expired

**Symptom:** Move Disk or disk creation fails with `401 Unauthorized` or `TrueNAS API token not configured`.

TrueNAS API keys can be revoked manually or expire under rotation policies. If this happens:
1. Generate a new API key on TrueNAS (same process as initial setup)
2. In Proxmox: Datacenter → Storage → select the storage → Edit → update the API Key field
3. Retry the failed operation

---

## Getting help

If you hit a problem not covered here:

1. Collect the relevant log output:
   ```bash
   journalctl -u pvedaemon --since '1 hour ago' | grep -i truenas > /tmp/pvedaemon.log
   ```
2. Note your versions: `dpkg -l truenas-proxmox`, PVE version (`pveversion`), TrueNAS version
3. Open an issue at https://github.com/TheGrandWazoo/freenas-proxmox/issues with the log and version info
