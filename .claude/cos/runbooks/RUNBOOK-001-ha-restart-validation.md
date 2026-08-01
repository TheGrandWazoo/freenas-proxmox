# RUNBOOK-001: HA Daemon Restart Validation

## Purpose

Validate that `truenas-proxmox` install/upgrade/remove correctly restarts the
Proxmox HA daemons (`pve-ha-lrm`, `pve-ha-crm`), so HA-managed VMs on TrueNAS
storage can start after a plugin install. Ref: #179.

This is manual because it needs a real PVE cluster with HA configured — the
stub-based CI test (`tests/test-restart-services.sh`) covers the shell-level
regression (right subcommands, correct `set -e` failure propagation) but
cannot exercise the actual `pve-ha-lrm`/`pve-ha-crm` HA resource-manager
behavior or a real HA-managed VM start/stop cycle.

## Background

`postinst`/`postrm` patch `PVE::Storage` and must restart every PVE daemon
that has that module loaded in memory: `pvedaemon`, `pveproxy`, `pvestatd`,
`pve-ha-lrm`, `pve-ha-crm`. Missing the HA daemons leaves them running
against the pre-install state, so HA-managed VMs on TrueNAS/multipath
storage fail to start with errors like:

```
pve-ha-lrm: storage 'TrueNAS' does not exist
TASK ERROR: freenas: unknown iscsi provider. Available [comstar, istgt, iet, LIO]
```

`pve-ha-lrm`/`pve-ha-crm` binaries only support `start`/`stop`/`status`/`help`
— no `restart` subcommand — so they're restarted via `systemctl restart`
instead of the `<daemon> restart` form used for `pvedaemon`/`pveproxy`/`pvestatd`.

## Prerequisites

- At least one lab PVE node with HA enabled (an HA group + one HA-managed
  resource is enough; a full multi-node failover isn't required for this check).
- TrueNAS storage configured and reachable from that node.
- SSH access (see `reference_ssh` memory for node FQDNs/keys).

## Procedure

1. **Install/upgrade the package** on the target node and confirm all five
   services restart in the log:
   ```
   ssh -i ~/.ssh/<node> root@<node>.ksatechnologies.com \
     "apt install --reinstall truenas-proxmox && tail -20 /var/log/truenas-proxmox-install.log"
   ```
   Expect log lines for `pvedaemon`, `pveproxy`, `pvestatd`, and
   `pve-ha-lrm, pve-ha-crm restarted`.

2. **Confirm the HA daemons are actually active post-restart:**
   ```
   systemctl is-active pvedaemon pveproxy pvestatd pve-ha-lrm pve-ha-crm
   ```
   All five must report `active`.

3. **Create (or reuse) an HA-managed VM on TrueNAS storage:**
   - VM disk on the `truenas:` (or `truenas-multipath:`) storage.
   - Add the VM to an HA group (`max-started=1`, `requested state=started`).

4. **Stop the VM via HA, then start it via HA** (not a manual `qm start`):
   ```
   ha-manager set vm:<vmid> --state stopped
   # wait for TASK OK
   ha-manager set vm:<vmid> --state started
   ```

5. **Confirm the HA-initiated start succeeds** — no
   `storage 'TrueNAS' does not exist` or `unknown iscsi provider` errors in
   the task log, and the VM reaches `running` state.

6. **Repeat step 1–5 for `apt remove`/`purge`** if validating the `postrm`
   path (less critical — removal restarts should be a no-op for HA behavior
   since the plugin file is gone either way, but confirms the restarts
   themselves don't error).

## Pass/Fail

- **Pass:** HA-initiated start succeeds with no storage-provider errors.
- **Fail:** Any HA-initiated start error referencing the TrueNAS storage —
  re-check `packaging/DEBIAN/postinst` `restart_pve_services()` for a missed
  daemon or a regression back to the `cmd && log ...` pattern (see
  `tests/test-restart-services.sh` for why that pattern is unsafe under
  `set -e`).

## Known gaps

- `packaging/DEBIAN-multipath/postinst`/`postrm` do not yet restart
  `pvestatd`/`pve-ha-lrm`/`pve-ha-crm` at all (still only `pvedaemon`/
  `pveproxy`). Same root cause as #179, not yet fixed there — file as a
  follow-up if multipath + HA is in active use.
