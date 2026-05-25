# freenas-proxmox v3.0 — Architecture & Developer Guide

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Per-VM iSCSI Target Model](#2-per-vm-iscsi-target-model)
3. [The `iscsi://` Path Model](#3-the-iscsi-path-model)
4. [API Flow — TrueNAS REST v2.0](#4-api-flow--truenas-rest-v20)
5. [alloc_image Deep Dive](#5-alloc_image-deep-dive)
6. [free_image Deep Dive](#6-free_image-deep-dive)
7. [Build Pipeline and Version/Channel Routing](#7-build-pipeline-and-versionchannel-routing)
8. [Debugging Guide](#8-debugging-guide)
9. [Contributing](#9-contributing)

---

## 1. Architecture Overview

### Where This Plugin Sits

Proxmox VE organizes storage backends through a plugin registry. Every storage type — directory, LVM, Ceph, ZFS-over-iSCSI — is a Perl module that subclasses `PVE::Storage::Plugin`. The `pvedaemon` process loads all registered storage plugins at startup and delegates storage operations (create volume, delete volume, list volumes, etc.) to the correct plugin based on the `type` field in `/etc/pve/storage.cfg`.

`PVE::Storage::Custom::TrueNAS` is loaded by PVE's auto-discovery mechanism. Any module installed under `/usr/share/perl5/PVE/Storage/Custom/` is automatically registered as a custom storage type. No patching of PVE's core `ZFSPlugin.pm`, `pvemanagerlib.js`, or `apidoc.js` is required — this is the fundamental architectural change from v2.x.

```
Proxmox VE (pvedaemon)
  └─ PVE::Storage                         # core storage dispatch
       └─ PVE::Storage::Custom::TrueNAS   # this plugin
            └─ TrueNAS REST API v2.0      # all state lives here
                 ├─ /pool/dataset         # zvol create/delete/resize
                 └─ /iscsi/*              # extent, target, targetextent CRUD
```

### What the Plugin Manages

The plugin manages the entire lifecycle of iSCSI-backed block devices on behalf of Proxmox VE:

- **ZFS volumes (zvols)** — the actual block storage, created and destroyed via `POST /pool/dataset` and `DELETE /pool/dataset/id/{id}`
- **iSCSI extents** — TrueNAS's representation of a device to export over iSCSI, one per zvol
- **iSCSI targets** — the access point a client connects to, one per VM (`proxmox-vm-<vmid>`)
- **targetextent mappings** — the join record linking an extent to a target at a specific LUN ID

The plugin does NOT manage the iSCSI initiator side. QEMU's built-in libiscsi opens the `iscsi://` URI returned by `path()` directly, without any host-side session management via `iscsiadm`.

### What the Plugin Does Not Do

- **Pool listing**: Proxmox's `status()` call returns pool capacity via the TrueNAS API, but ZFS pool enumeration for the "Add Storage" wizard still requires SSH access through PVE's upstream `ZFSPoolPlugin.pm`. This is a Proxmox limitation outside the plugin's scope.
- **Snapshots on PVE 8.x**: The `volume_snapshot` family of methods is defined but will return an unsupported error on PVE 8. PVE 9.0's Snapshot-as-Volume-Chains feature is the target integration point (v3.1.0, ADR-008).
- **TPM state disks**: swtpm (the virtual TPM backend) cannot use `iscsi://` URIs; it requires a local filesystem path. TPM disks must be placed on a different storage type.

### Installed File Locations

| File | Destination on Proxmox host |
|---|---|
| `perl5/PVE/Storage/Custom/TrueNAS.pm` | `/usr/share/perl5/PVE/Storage/Custom/TrueNAS.pm` |
| `ui/truenas-storage.js` | `/usr/share/pve-manager/js/truenas-storage.js` |
| One `<script>` tag | Injected into `/usr/share/pve-manager/index.html.tpl` |

`postinst` copies both files, injects the script tag into `index.html.tpl` (idempotent — skipped if already present), and restarts `pvedaemon` and `pveproxy`.

---

## 2. Per-VM iSCSI Target Model

### Why Per-VM Targets

The v2.x approach used a single shared iSCSI target for all VMs. Every disk from every VM was a different LUN on the same target IQN. This created several problems:

- Deleting one disk required stopping the iSCSI service (`force=true` on extent delete does not work cleanly when multiple active sessions are on the same target)
- Live migration of a single disk while others on the same target are active caused session disruption
- LUN exhaustion — TrueNAS has a practical limit of 256 LUNs per target

In v3.0, each VM gets its own iSCSI target: `proxmox-vm-<vmid>`. Disks belonging to that VM become LUN 0, LUN 1, LUN 2, etc. on that target.

### The TrueNAS Object Graph

For a VM with `vmid=100` and two disks, TrueNAS holds:

```
ZFS pool "tank"
  └── tank/proxmox/vdisks/
       ├── vm-100-disk-0   (zvol, 32 GiB)
       └── vm-100-disk-1   (zvol, 64 GiB)

iSCSI extents
  ├── vm-100-disk-0   (type=DISK, disk=zvol/tank/proxmox/vdisks/vm-100-disk-0)
  └── vm-100-disk-1   (type=DISK, disk=zvol/tank/proxmox/vdisks/vm-100-disk-1)

iSCSI target
  └── proxmox-vm-100   (IQN: iqn.2005-10.org.freenas.ctl:proxmox-vm-100)

targetextent mappings
  ├── target=proxmox-vm-100, extent=vm-100-disk-0, lunid=0
  └── target=proxmox-vm-100, extent=vm-100-disk-1, lunid=1
```

### Target Lifecycle

**Creation**: `_resolve_vm_target($scfg, $vmid)` is called on the first `alloc_image` for a VM. It queries `GET /iscsi/target`, looks for an entry with `name eq "proxmox-vm-$vmid"`, and creates one via `POST /iscsi/target` if it does not exist. The new target is assigned the same portal group and initiator group settings as an existing reference target (the `truenas_target` config value, or any existing target on the configured portal IP, as a fallback).

**Portal group discovery** (`_portal_groups_for_new_target`): Queries `GET /iscsi/portal` and finds all portals listening on the configured `truenas_portal_ip` (or `0.0.0.0`/`::`). Then queries `GET /iscsi/target` and finds the groups from the base target that reference those portal IDs. These groups are cloned for the new per-VM target, preserving `portal`, `initiator`, `authmethod`, and `auth` settings.

**Deletion**: `_maybe_cleanup_vm_target($scfg, $vmid, $target_id)` is called after each disk is removed. It queries `GET /iscsi/targetextent?target=<id>` to check for remaining extents. If the target is now empty, it is deleted via `DELETE /iscsi/target/id/<id>`. This keeps TrueNAS clean — no accumulation of empty targets.

**Runtime caching**: Both the target lookup and the global iSCSI config (`GET /iscsi/global`) are cached in the module-level `$state` hashref, keyed by `truenas_host`. `deactivate_storage` clears the entire cache for a host.

---

## 3. The `iscsi://` Path Model

### How QEMU Connects

The `path()` method returns a URI of the form:

```
iscsi://<portal_ip>/<iqn>/<lun_id>
```

Example:

```
iscsi://192.168.1.50/iqn.2005-10.org.freenas.ctl:proxmox-vm-100/0
```

QEMU implements libiscsi internally. When it receives an `iscsi://` path, it opens an iSCSI session directly from the QEMU process to the TrueNAS portal. No `iscsiadm` command is run, no kernel iSCSI session is created, and no `/dev/sdX` or `/dev/disk/by-path/` device node appears on the Proxmox host.

### How `path()` Works Internally

```perl
sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    my $ext = _find_extent($scfg, $volname);
    my $t      = _api($scfg, 'GET', "/iscsi/target/id/$ext->{target_id}");
    my $iqn    = _basename($scfg) . ":$t->{name}";
    my $portal = _portal($scfg);
    return ("iscsi://$portal/$iqn/$ext->{lun_id}", $vmid, $vtype);
}
```

`_find_extent` calls `GET /iscsi/extent` to locate the extent by name, then `GET /iscsi/targetextent?extent=<id>` to find the LUN ID and target association. The IQN is assembled from the cached global basename (`GET /iscsi/global` → `basename` field) and the target name.

### activate_volume and deactivate_volume

Because QEMU manages the connection itself, `activate_volume` only verifies that the extent exists (catching configuration errors early) and logs readiness. It does not call `iscsiadm login` or any iSCSI session management command. `deactivate_volume` is a no-op.

### Constraints of the iscsi:// Model

- **No multipath**: libiscsi in QEMU does not do multipath. If the portal is unreachable, QEMU retries but does not fail over to a second portal. Multi-portal TrueNAS setups are not effective with this model (tracked for v3.1.0, #256).
- **TPM disks excluded**: `swtpm` cannot use `iscsi://` URIs. Any disk assigned to a VM's TPM must be on a different storage type (e.g., local-lvm, directory).
- **No host-visible device**: Because there is no kernel iSCSI session, tools like `lsscsi`, `iscsiadm --mode session`, or `ls /dev/disk/by-path` will not show the disk on the Proxmox host. This is expected and correct.

---

## 4. API Flow — TrueNAS REST v2.0

### Authentication

All requests use `Authorization: Bearer <token>` with the API key stored in `truenas_api_key` in storage.cfg. Basic auth was removed in v3.0 (ADR-005). The API key is generated in TrueNAS under:

- SCALE: System Settings → API Keys → Add
- CORE 13: gear icon (top right) → API Keys → Add

### Transport

The plugin uses `LWP::UserAgent` with a 30-second timeout. A single `LWP::UserAgent` instance is created per `truenas_host` and cached in `$state->{$host}{ua}`. SSL verification is off by default (`truenas_ssl_verify => 0`) to accommodate self-signed certificates. When `truenas_ssl_verify` is false, `ssl_opts(verify_hostname => 0, SSL_verify_mode => 0)` is applied to the UA.

### The `_api` Function

All TrueNAS calls go through `_api($scfg, $method, $path, $data)`:

```perl
sub _api {
    my ($scfg, $method, $path, $data) = @_;

    my $url = "$scheme://$scfg->{truenas_host}/api/v2.0$path";
    my $req = HTTP::Request->new(uc($method) => $url);
    $req->header('Authorization' => "Bearer $scfg->{truenas_api_key}");
    $req->content(encode_json($data)) if defined $data;

    my $res = _ua($scfg)->request($req);
    die "TrueNAS API $method $path: " . $res->status_line unless $res->is_success;
    return decode_json($res->content);
}
```

On HTTP error, the function extracts the `message` field from the JSON response body, logs it via `syslog('err', ...)`, and dies with a descriptive string. HTTP 204 (No Content) responses — returned by most DELETE calls — return `undef` cleanly.

### Endpoints Used

| Operation | Method | Endpoint |
|---|---|---|
| Global iSCSI config | GET | `/iscsi/global` |
| List portals | GET | `/iscsi/portal` |
| List targets | GET | `/iscsi/target` |
| Get target by ID | GET | `/iscsi/target/id/{id}` |
| Create target | POST | `/iscsi/target` |
| Delete target | DELETE | `/iscsi/target/id/{id}` |
| List extents | GET | `/iscsi/extent` |
| Create extent | POST | `/iscsi/extent` |
| Delete extent | DELETE | `/iscsi/extent/id/{id}` |
| List targetextents (by target) | GET | `/iscsi/targetextent?target={id}` |
| List targetextents (by extent) | GET | `/iscsi/targetextent?extent={id}` |
| Create targetextent | POST | `/iscsi/targetextent` |
| Delete targetextent | DELETE | `/iscsi/targetextent/id/{id}` |
| Reload iSCSI service | POST | `/service/reload` |
| Get pool dataset | GET | `/pool/dataset?id={pool}` |
| Get zvol by ID | GET | `/pool/dataset/id/{encoded_path}` |
| List all zvols | GET | `/pool/dataset?type=VOLUME` |
| Create zvol | POST | `/pool/dataset` |
| Delete zvol | DELETE | `/pool/dataset/id/{encoded_path}` |

### URL Encoding for Dataset Paths

TrueNAS uses the full ZFS dataset path as the resource identifier in DELETE and GET by-ID calls. Forward slashes must be URL-encoded. The plugin uses `URI::Escape::uri_escape($path, "^A-Za-z0-9\\-_.~")` which encodes `/` as `%2F`:

```perl
my $enc = uri_escape("tank/proxmox/vdisks/vm-100-disk-0", "^A-Za-z0-9\\-_.~");
# Result: tank%2Fproxmox%2Fvdisks%2Fvm-100-disk-0
_api($scfg, 'DELETE', "/pool/dataset/id/$enc", { recursive => JSON::true });
```

### iSCSI Service Reload

After creating a new extent and targetextent, the plugin calls:

```perl
_api($scfg, 'POST', '/service/reload', { service => 'iscsitarget' });
```

This signals TrueNAS to reload its iSCSI configuration so the new LUN is visible to connecting initiators. The reload is non-fatal — if it fails, a warning is logged but `alloc_image` still succeeds.

---

## 5. alloc_image Deep Dive

`alloc_image($class, $storeid, $scfg, $vmid, $fmt, $name, $size_kb)` is called by PVE when a new virtual disk is created.

### Step 1: Name Resolution

If `$name` is not supplied, `find_free_diskname` (base-class method) generates `vm-<vmid>-disk-<N>` where `N` is the lowest unused integer. Only `raw` format is accepted.

### Step 2: Zvol Creation

```perl
_api($scfg, 'POST', '/pool/dataset', {
    name    => "$prefix/$name",   # e.g. tank/proxmox/vdisks/vm-100-disk-0
    type    => 'VOLUME',
    volsize => $size_kb * 1024,   # API takes bytes
    sparse  => JSON::true,
});
```

`$prefix` is assembled by `_zvol_prefix`: `truenas_pool` + optionally `/ truenas_dataset`. Sparse provisioning is always on.

### Step 3: iSCSI Extent Creation

```perl
_api($scfg, 'POST', '/iscsi/extent', {
    name => $name,                        # e.g. vm-100-disk-0
    type => 'DISK',
    disk => "zvol/$prefix/$name",         # zvol/ prefix required by TrueNAS
    ro   => JSON::false,
});
```

The extent name matches the volume name exactly. This 1:1 naming is load-bearing — `_find_extent` searches extents by name.

### Step 4: Per-VM Target Resolution

`_resolve_vm_target($scfg, $vmid)` returns `{ id, iqn }`. If the target does not yet exist, it is created here. LUN ID assignment (`_next_lun_id`): queries `GET /iscsi/targetextent?target=<id>` and returns the lowest unused non-negative integer.

### Step 5: targetextent Creation

```perl
_api($scfg, 'POST', '/iscsi/targetextent', {
    target => $target_id,
    extent => $extent_id,
    lunid  => $lun_id,
});
```

### Step 6: Service Reload and Return

`_reload_iscsi` triggers the TrueNAS iSCSI service reload. The function returns `$name`, which PVE stores in the VM config.

### Rollback on Failure

The current implementation does not explicitly roll back a partially-created extent if targetextent creation fails — the extent and zvol remain on TrueNAS. ADR-004 documents the intended `eval {}` rollback pattern. This is tracked as a known gap in issue #250.

---

## 6. free_image Deep Dive

`free_image($class, $storeid, $scfg, $volname, $isBase)` is called when a disk is deleted. The deletion order is deliberately sequenced to avoid dangling references.

### Step 1: Locate the Extent

`_find_extent($scfg, $volname)` calls `GET /iscsi/extent` (by name) then `GET /iscsi/targetextent?extent=<id>`. Returns `{ extent_id, targetextent_id, lun_id, target_id }`. If no extent exists, a warning is logged and extent removal is skipped.

### Step 2: Unmap the targetextent

```perl
_api($scfg, 'DELETE', "/iscsi/targetextent/id/$ext->{targetextent_id}");
```

This must happen before the extent DELETE. Removing the targetextent severs this LUN's association without affecting the target session or other LUNs on the same target — critical for the live-migration case.

### Step 3: Delete the Extent

```perl
_api($scfg, 'DELETE', "/iscsi/extent/id/$ext->{extent_id}", { force => JSON::true });
```

`force=true` is required to delete an extent that may still have a residual QEMU libiscsi session open (e.g., detached disk on a running VM).

### Step 4: Clean Up the Per-VM Target if Empty

`_maybe_cleanup_vm_target($scfg, $vmid, $target_id)` queries `GET /iscsi/targetextent?target=<id>` after the targetextent was removed. If no mappings remain, `DELETE /iscsi/target/id/<id>` removes the empty target.

### Step 5: Delete the Zvol

```perl
my $enc = uri_escape($zvol, "^A-Za-z0-9\\-_.~");
_api($scfg, 'DELETE', "/pool/dataset/id/$enc", { recursive => JSON::true });
```

`recursive=true` handles any ZFS snapshots under the zvol. Zvol deletion is last — if it fails, the error propagates after extent and targetextent are already cleaned up.

---

## 7. Build Pipeline and Version/Channel Routing

### Single-Repo Architecture (ADR-001)

All build and packaging logic lives in `.github/workflows/build.yml`. The old two-repo dispatch approach (this repo → `freenas-proxmox-packer`) was eliminated. Files are embedded in the `.deb` at build time; no `git clone` or `patch` runs at install time.

### Four-Job Pipeline

```
lint → build → security → publish
```

**Job 1: Lint**
- `perl -c -I/tmp/pve-stub perl5/PVE/Storage/Custom/TrueNAS.pm` — syntax check with PVE module stubs
- `perlcritic --profile .perlcriticrc` — static analysis at severity 4
- `shellcheck --severity=warning packaging/DEBIAN/postinst packaging/DEBIAN/postrm`

**Job 2: Build**
- Reads `our $VERSION` from `TrueNAS.pm` as the base version (ADR-006)
- Resolves version string and target channel based on `$GITHUB_REF`
- Generates `dist/DEBIAN/control` from `packaging/DEBIAN/control.j2` via `sed`
- Runs `dpkg-deb -Zgzip --build dist <deb_file>`
- Uploads the `.deb` as a workflow artifact (30-day retention)

**Job 3: Security**
- Trivy filesystem scan (secrets + misconfig) on the repository
- Trivy scan of extracted `.deb` contents (vuln + secret)
- Both scans use `exit-code: 1` — HIGH or CRITICAL findings fail the pipeline

**Job 4: Publish**
- Skipped for PRs and branches with `channel=none`
- Cloudsmith `deb` push to the resolved repo
- On tagged releases: creates a draft GitHub Release with the `.deb` attached

### Version String Logic

| Git ref | Debian version string | Channel | Cloudsmith repo |
|---|---|---|---|
| `refs/tags/v3.0.0` | `3.0.0-1` | stable | `truenas-proxmox` |
| `refs/heads/master` or `refs/heads/release/3.x` | `3.0.0~beta+abc1234` | testing | `truenas-proxmox-testing` |
| `refs/heads/release/*` (other) | `3.0.0~alpha+abc1234` | development | `truenas-proxmox-snapshots` |
| feature branches, PRs | `3.0.0~dev+abc1234` | none | not published |

The tilde (`~`) in the Debian version sorts below the base version in `dpkg`, guaranteeing pre-release builds never auto-upgrade over a stable release.

### Running the Build Locally

```bash
# Install dependencies
sudo apt-get install -y libperl-critic-perl shellcheck libwww-perl libjson-perl liburi-perl

# Create PVE stubs
mkdir -p /tmp/pve-stub/PVE/Storage
printf 'package PVE::SafeSyslog;\nuse Exporter "import";\nour @EXPORT = qw(syslog);\nsub syslog {}\n1;\n' \
  > /tmp/pve-stub/PVE/SafeSyslog.pm
printf 'package PVE::Tools;\nuse Exporter "import";\nour @EXPORT_OK = qw(run_command);\nsub run_command {}\n1;\n' \
  > /tmp/pve-stub/PVE/Tools.pm
printf 'package PVE::Storage::Plugin;\nsub new {}\nsub register {}\nsub lookup_types { [] }\nsub properties { {} }\nsub options { {} }\n1;\n' \
  > /tmp/pve-stub/PVE/Storage/Plugin.pm

# Syntax check + lint
perl -c -I/tmp/pve-stub perl5/PVE/Storage/Custom/TrueNAS.pm
perlcritic --profile .perlcriticrc perl5/PVE/Storage/Custom/TrueNAS.pm
shellcheck --severity=warning packaging/DEBIAN/postinst packaging/DEBIAN/postrm

# Build the package
VERSION="3.0.0-dev"
mkdir -p dist/DEBIAN dist/usr/share/freenas-proxmox
sed "s/\${VERSION}/$VERSION/" packaging/DEBIAN/control.j2 > dist/DEBIAN/control
cp packaging/DEBIAN/postinst packaging/DEBIAN/postrm dist/DEBIAN/
chmod 0755 dist/DEBIAN/postinst dist/DEBIAN/postrm
cp perl5/PVE/Storage/Custom/TrueNAS.pm dist/usr/share/freenas-proxmox/TrueNAS.pm
cp ui/truenas-storage.js               dist/usr/share/freenas-proxmox/truenas-storage.js
sudo dpkg-deb -Zgzip --build dist freenas-proxmox_${VERSION}_all.deb
```

---

## 8. Debugging Guide

### Layer Model

Errors fall into one of four distinct layers:

```
PVE task / VM operation
  └─ Plugin (TrueNAS.pm) — syslog "TrueNASPlugin: ..."
       └─ TrueNAS REST API — HTTP errors, JSON responses
            └─ iSCSI / QEMU libiscsi — QEMU logs, dmesg
                 └─ ZFS — TrueNAS ZFS pool logs
```

### Plugin Logs (Layer 1)

```bash
# All plugin messages
grep -i 'TrueNASPlugin' /var/log/syslog

# Follow live
tail -f /var/log/syslog | grep -i TrueNAS
```

Log levels: `info` (normal operation), `warning` (non-fatal issues), `err` (fatal — operation dies).

Example sequence for a successful `alloc_image`:

```
TrueNASPlugin: alloc_image: creating zvol tank/proxmox/vdisks/vm-100-disk-0 (34359738368 bytes) for VM 100
TrueNASPlugin: Created per-VM target: iqn.2005-10.org.freenas.ctl:proxmox-vm-100 (id=42)
TrueNASPlugin: alloc_image: vm-100-disk-0 ready at lun 0 on iqn.2005-10.org.freenas.ctl:proxmox-vm-100
```

### PVE Task Logs (Layer 1)

```bash
# Recent storage tasks
pvesh get /nodes/<nodename>/tasks --limit 50 | grep -i storage

# Specific task log
pvesh get /nodes/<nodename>/tasks/<upid>/log

# VM start failures
tail -f /var/log/pve/qemu-server/<vmid>.log
```

### TrueNAS API Errors (Layer 2)

Common errors and causes:

| Error | Likely cause |
|---|---|
| `401 Unauthorized` | API key missing, revoked, or wrong |
| `404 Not Found` on extent DELETE | Extent already deleted or never created |
| `422 Unprocessable Entity` | Payload validation error — check TrueNAS system log for detail |
| `500 Internal Server Error` | TrueNAS-side error — check TrueNAS system log |
| Connection refused / timeout | TrueNAS host unreachable; check `truenas_host` or `truenas_portal_ip` |

**Probe the API manually:**

```bash
# Test connectivity and auth
curl -sk -H "Authorization: Bearer <token>" \
  https://<truenas_host>/api/v2.0/iscsi/global | python3 -m json.tool

# List all extents
curl -sk -H "Authorization: Bearer <token>" \
  https://<truenas_host>/api/v2.0/iscsi/extent | python3 -m json.tool

# List all targetextents
curl -sk -H "Authorization: Bearer <token>" \
  https://<truenas_host>/api/v2.0/iscsi/targetextent | python3 -m json.tool
```

### Dangling Resources (Layer 2)

If `alloc_image` fails partway through, orphaned extents may remain on TrueNAS. Identify unmapped extents:

```bash
# Get all extent IDs
curl -sk -H "Authorization: Bearer $TOKEN" \
  https://<truenas>/api/v2.0/iscsi/extent | python3 -c \
  "import json,sys; [print(e['id'],e['name']) for e in json.load(sys.stdin)]"

# Get all mapped extent IDs
curl -sk -H "Authorization: Bearer $TOKEN" \
  https://<truenas>/api/v2.0/iscsi/targetextent | python3 -c \
  "import json,sys; [print(te['extent']) for te in json.load(sys.stdin)]"
```

Manual cleanup of a dangling extent:

```bash
curl -sk -X DELETE -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"force": true}' \
  https://<truenas>/api/v2.0/iscsi/extent/id/<id>
```

### iSCSI / QEMU Connection Issues (Layer 3)

```bash
tail -f /var/log/pve/qemu-server/<vmid>.log
```

Common libiscsi errors:

| Error | Meaning |
|---|---|
| `Failed to connect to iSCSI portal` | Portal IP wrong, TrueNAS iSCSI service not running, or firewall |
| `Initiator has no access to this target` | Initiator group does not include the Proxmox node's IQN |
| `LUN not found` | Extent not mapped, or iSCSI service not reloaded after extent creation |
| `Target not found` | IQN mismatch — check `_basename()` vs TrueNAS's actual global basename |

Check the Proxmox node's initiator IQN:

```bash
cat /etc/iscsi/initiatorname.iscsi
```

### Plugin Not Loading

```bash
grep -i 'TrueNAS\|Storage::Custom\|Can.t locate' /var/log/syslog

# Verify syntax directly
perl -c /usr/share/perl5/PVE/Storage/Custom/TrueNAS.pm

# Check required Perl modules
dpkg -l libwww-perl libjson-perl liburi-perl libio-socket-ssl-perl
```

### Install / Removal Log

```bash
cat /var/log/freenas-proxmox-install.log
```

---

## 9. Contributing

### Quick Iteration on a Live Proxmox Node

For changes to `TrueNAS.pm` only:

```bash
scp perl5/PVE/Storage/Custom/TrueNAS.pm \
    root@<proxmox-node>:/usr/share/perl5/PVE/Storage/Custom/TrueNAS.pm
ssh root@<proxmox-node> "pvedaemon restart && pveproxy restart"
```

For UI changes (`truenas-storage.js`):

```bash
scp ui/truenas-storage.js \
    root@<proxmox-node>:/usr/share/pve-manager/js/truenas-storage.js
# Hard-refresh browser (Ctrl+Shift+R) — no service restart needed
```

### Coding Standards

**Perl:**
- `use strict` and `use warnings` — no exceptions
- All TrueNAS API calls through `_api()` — never raw `LWP::UserAgent` outside that function
- Multi-step operations must use `eval {}` rollback: if step N fails, undo steps 1 through N-1 in reverse before dying (ADR-004)
- `JSON::true` / `JSON::false` for boolean JSON fields

**Shell (`postinst`/`postrm`):**
- `set -e` at top
- All output via the `log()` function (writes to `$LOG_FILE`)
- Operations must be idempotent — check before acting
- `shellcheck --severity=warning` must pass

### Branch and PR Workflow

1. Open a GitHub issue before writing code
2. Branch from `master`: `git checkout -b feature/short-description`
3. Run lint locally before pushing
4. Open a PR against `master` — CI runs lint → build → security automatically
5. Close the issue with commit SHA and version when the change ships

### Architecture Decision Records

Major design decisions live in `.claude/cos/adrs/`. Check before making changes that affect the plugin's architecture, auth model, build pipeline, or supported platform matrix.

| ADR | Decision |
|---|---|
| ADR-001 | Consolidate build pipeline into this repo; no install-time git clone |
| ADR-002 | Full `PVE::Storage::Custom` plugin; no ZFSPlugin.pm or pvemanagerlib.js patches |
| ADR-003 | Transition from Cloudsmith to GitHub Pages apt repo (accepted, not yet implemented) |
| ADR-004 | `eval {}` rollback pattern for all multi-step TrueNAS operations |
| ADR-005 | Bearer token (API key) as primary auth; basic auth removed in v3.0 |
| ADR-006 | `$VERSION` in `TrueNAS.pm` is the single source of truth for package versioning |
| ADR-007 | v2.x keeps `FreeNAS` naming; v3.x uses `TrueNAS` everywhere |
| ADR-008 | v3.0 supports PVE 8+ (core); PVE 9+ snapshot interface targeted for v3.1.0 |

---

## Key File Reference

| File | Purpose |
|---|---|
| [perl5/PVE/Storage/Custom/TrueNAS.pm](../perl5/PVE/Storage/Custom/TrueNAS.pm) | Main plugin — all storage operations |
| [ui/truenas-storage.js](../ui/truenas-storage.js) | Ext.js UI panel for the `truenas` storage type |
| [packaging/DEBIAN/postinst](../packaging/DEBIAN/postinst) | Install script — copies files, injects script tag, restarts PVE |
| [packaging/DEBIAN/postrm](../packaging/DEBIAN/postrm) | Removal script — reverses postinst changes |
| [packaging/DEBIAN/control.j2](../packaging/DEBIAN/control.j2) | Debian package control file template |
| [.github/workflows/build.yml](../.github/workflows/build.yml) | Full CI/CD pipeline |
| [.claude/cos/adrs/](../.claude/cos/adrs/) | Architecture Decision Records |
