# Getting Started with freenas-proxmox v3.0

## 1. What This Plugin Does

Proxmox VE is a hypervisor — it runs your virtual machines. Those VMs need somewhere to store their disk images. If you have a TrueNAS storage server on your network, you might want to store those disks on TrueNAS so they live on dedicated, reliable, ZFS-managed storage instead of inside the Proxmox host itself. This plugin makes that possible. It registers a new storage type called **TrueNAS (ZFS/iSCSI)** inside Proxmox. When you add a VM disk to that storage, Proxmox talks to your TrueNAS server through its REST API, creates a ZFS volume on TrueNAS, exposes it as an iSCSI block device, and gives your VM a direct high-speed path to it — all automatically. You do not need to touch the TrueNAS UI every time you create or delete a VM disk.

---

## 2. Prerequisites

Complete all of these before installing the plugin.

### 2.1 Proxmox VE Version

Your Proxmox VE node (or cluster) must be running **PVE 8.x or PVE 9.x**. Check with:

```bash
pveversion
```

If the output shows `pve-manager/7.x`, stay on plugin v2.x — v3.0 does not support PVE 7.

### 2.2 TrueNAS Version

| TrueNAS product | Minimum version |
|:----------------|:----------------|
| TrueNAS SCALE   | Electric Eel (24.10) or later |
| TrueNAS CORE    | 13.0-U6 or later |

### 2.3 iSCSI Service on TrueNAS

The plugin creates per-VM iSCSI targets for you automatically. It does **not** create the iSCSI service infrastructure — you must set that up once.

**On TrueNAS SCALE:**
1. Go to **Shares → iSCSI → Configure**
2. Under **Portals**, add a portal that listens on the IP address your Proxmox nodes use to reach TrueNAS (or `0.0.0.0` to listen on all interfaces). Note the portal's IP address — you will need it.
3. Under **Initiators**, add an initiator group. You can leave it open (allow all) for initial setup; lock it down to specific Proxmox node IPs later.
4. Enable the iSCSI service and confirm it is running.

**On TrueNAS CORE:**
1. Go to **Sharing → Block Shares (iSCSI)**
2. Under **Portals**, add a portal (same as above)
3. Under **Initiators**, add an initiator group
4. Go to **Services** and enable **iSCSI**

You do **not** need to create any targets or extents by hand — the plugin creates those automatically when you allocate VM disks.

### 2.4 TrueNAS API Key

The plugin authenticates with TrueNAS using an API key (Bearer token). No username or password is used.

**On TrueNAS SCALE:**
Go to **System Settings → API Keys → Add**. Give it a descriptive name such as `proxmox-plugin`. Copy the key — it is shown only once.

**On TrueNAS CORE:**
Click the gear icon in the top-right corner → **API Keys → Add**. Copy the key.

Store the key somewhere safe temporarily. You will paste it into the Proxmox UI during storage configuration.

### 2.5 Network Reachability

- Every Proxmox node must be able to reach the TrueNAS host on **TCP 443** (HTTPS API) or **TCP 80** (HTTP, not recommended)
- Every Proxmox node must be able to reach the iSCSI portal on **TCP 3260**

No SSH keys are required. No pre-created iSCSI targets are required.

### 2.6 What You Cannot Store on This Storage

TPM state disks (`tpmstate0`) cannot live on this storage type. If you plan to create VMs with Secure Boot / TPM enabled, configure a separate local-lvm or NFS storage for those disks. All other disk types (virtio, scsi, IDE, EFI) work normally.

---

## 3. Installation

Run all of these commands on **each Proxmox node** in your cluster, or on your single Proxmox host. Run them as root.

### Step 1 — Import the GPG Signing Key

```bash
curl -fsSL https://dl.cloudsmith.io/public/ksatechnologies/truenas-proxmox/gpg.284C106104A8CE6D.key \
  | gpg --dearmor \
  | tee /usr/share/keyrings/ksatechnologies-truenas-proxmox-keyring.gpg > /dev/null
```

### Step 2 — Add the Package Repository

```bash
cat > /etc/apt/sources.list.d/ksatechnologies-repo.list << 'EOF'
deb [signed-by=/usr/share/keyrings/ksatechnologies-truenas-proxmox-keyring.gpg] \
  https://dl.cloudsmith.io/public/ksatechnologies/truenas-proxmox/deb/debian any-version main
EOF
```

### Step 3 — Install the Package

```bash
apt update && apt install truenas-proxmox
```

The installer:
- Copies `TrueNAS.pm` to `/usr/share/perl5/PVE/Storage/Custom/`
- Copies `truenas-storage.js` to `/usr/share/pve-manager/js/`
- Adds one `<script>` tag to `/usr/share/pve-manager/index.html.tpl` so the UI loads the new panel
- Restarts `pvedaemon` and `pveproxy`

It does **not** patch any PVE system files.

### Step 4 — Refresh Your Browser

Open (or reload) the Proxmox web UI. Do a hard refresh: **Ctrl+Shift+R** (Windows/Linux) or **Cmd+Shift+R** (Mac). The TrueNAS storage type will not appear until the browser picks up the new JavaScript.

---

## 4. First Storage Configuration in the Proxmox UI

In the Proxmox web UI:

1. Click **Datacenter** in the left tree
2. Click **Storage** in the top tabs
3. Click **Add**
4. Choose **TrueNAS (ZFS/iSCSI)** from the dropdown

If **TrueNAS (ZFS/iSCSI)** does not appear in the list, see [section 6.1](#61-truenas-zfsiscsi-does-not-appear-in-the-add-storage-dropdown) below.

### Field Reference

Fill in the form using the table below. Fields not listed can be left at their defaults.

| Field | What to enter | Notes |
|-------|---------------|-------|
| **ID** | A short name, e.g. `truenas-vms` | How Proxmox refers to the storage internally. Letters, numbers, and hyphens only. Cannot be changed later. |
| **TrueNAS Host** | IP address or hostname of your TrueNAS server | Example: `192.168.10.50` or `truenas.local`. Also used as the iSCSI portal address unless you set Portal IP separately. |
| **API Key** | Paste the API key you generated in step 2.4 | Treated as a password — hidden by default. Click the eye icon to show it while pasting. |
| **Pool / Dataset Path** | The ZFS pool or dataset path where VM disks should be created | Use `tank` for the pool root, or `tank/proxmox/vdisks` for a specific dataset. |
| **Use SSL** | Leave checked (on) | Recommended. Turn off only if TrueNAS has no HTTPS configured. |
| **Verify SSL Certificate** | Leave unchecked | Turn on only if TrueNAS has a valid CA-signed certificate. Most homelab setups use self-signed certs — leave this off. |
| **Shared** | Leave checked (on) | Required for clusters. Tells Proxmox all nodes can access this storage. |
| **Portal IP** | Optional — leave blank | If your TrueNAS management interface and iSCSI data interface are on different IPs, put the iSCSI data IP here. Otherwise the TrueNAS Host IP is used for both. |
| **Target IQN** | Optional — leave blank | The plugin auto-discovers the portal and initiator group from existing iSCSI targets. Leave blank unless you want to force it to copy settings from a specific target. |

Click **Add**. Proxmox contacts TrueNAS and confirms the pool is reachable. If it fails, check the error message — see [section 6](#6-common-first-run-problems) for common causes.

### 4.1 Securing the API Token (Recommended for Production)

By default the API token is stored in `/etc/pve/storage.cfg`, which is replicated in plaintext across all cluster nodes via the PVE cluster filesystem. For production deployments, move the token into a private keyfile that only root can read and that is not replicated.

Run these commands **on each Proxmox node** after adding the storage:

```bash
# Replace 'truenas-vms' with your actual storage ID
STORAGEID="truenas-vms"
KEYFILE="/etc/pve/priv/truenas-${STORAGEID}.key"

# Write the token to the keyfile (replace the value with your actual token)
echo -n "your-api-token-here" > "$KEYFILE"
chmod 600 "$KEYFILE"

# Remove the token from storage.cfg now that the keyfile is in place
pvesm set "$STORAGEID" --truenas_api_key ""
```

The plugin automatically checks `/etc/pve/priv/truenas-<storeid>.key` at startup. If the file exists, it is used and `truenas_api_key` in storage.cfg is ignored.

> **Note:** The keyfile must exist on **every Proxmox node** in your cluster. The `/etc/pve/priv/` directory is not replicated via pmxcfs — copy the file to each node manually (use `scp` or your configuration management tool).

---

## 5. Creating Your First VM Disk on TrueNAS Storage

### During VM Creation

1. In the Proxmox UI, click **Create VM**
2. On the **Disks** tab, change **Storage** from `local-lvm` to the storage ID you just created (e.g., `truenas-vms`)
3. Set the disk size
4. Complete the rest of the VM setup and click **Finish**

Proxmox will:
- Create a ZFS volume (`zvol`) on TrueNAS sized to your request
- Create an iSCSI extent pointing to that zvol
- Create a dedicated iSCSI target named `proxmox-vm-<vmid>` on TrueNAS (e.g., `proxmox-vm-100`)
- Map the extent to the target
- Give QEMU an `iscsi://` path to connect directly

When the VM starts, QEMU opens an iSCSI connection directly to TrueNAS — no kernel session management (`iscsiadm`) is involved.

### Adding a Disk to an Existing VM

1. Select the VM in the left tree
2. Click **Hardware**
3. Click **Add → Hard Disk**
4. Set **Storage** to your TrueNAS storage
5. Set the disk size
6. Click **Add**

### What You Will See on TrueNAS

After creating a VM disk, log into TrueNAS and check:
- **Datasets** (SCALE) or **Storage → Pools** (CORE): a new zvol named `vm-100-disk-0` (or similar) will appear under your configured pool/dataset
- **Shares → iSCSI → Targets**: a target named `proxmox-vm-100` will appear
- **Shares → iSCSI → Extents**: an extent named `vm-100-disk-0` will appear

When you delete the disk from Proxmox, all three are removed automatically. If the deleted disk was the last disk on that VM's target, the target is removed too.

---

## 6. Common First-Run Problems

### 6.1 "TrueNAS (ZFS/iSCSI)" Does Not Appear in the Add Storage Dropdown

**Cause:** Browser has cached the old Proxmox JavaScript.

**Fix:** Hard-refresh the browser: **Ctrl+Shift+R** (Windows/Linux) or **Cmd+Shift+R** (Mac). If it still does not appear, check that the package installed correctly:

```bash
ls /usr/share/perl5/PVE/Storage/Custom/TrueNAS.pm
ls /usr/share/pve-manager/js/truenas-storage.js
```

Both files should exist. If they are missing, re-run `apt install truenas-proxmox`. Also check whether `pvedaemon` and `pveproxy` restarted cleanly:

```bash
systemctl status pvedaemon pveproxy
```

### 6.2 Storage Shows as Unavailable or Add Dialog Returns an Error

**Cause:** The plugin cannot reach the TrueNAS API.

**Check the logs first:**

```bash
journalctl -u pvedaemon --since "10 minutes ago" | grep -i truenas
```

Common specific errors:

| Log message | Fix |
|-------------|-----|
| `TrueNAS API key is not configured` | API key field was left blank; edit the storage and paste the key |
| `401 Unauthorized` | API key is wrong, expired, or revoked; generate a new one in TrueNAS |
| `500 Internal Server Error` or connection refused | SSL mismatch — if TrueNAS uses a self-signed certificate and Use SSL is on, try toggling Verify SSL Certificate off. Or check that TrueNAS is reachable on HTTPS from the Proxmox node |
| `Pool dataset 'tank' not found` | The pool name you typed does not match what TrueNAS has; check under **Storage → Pools** in TrueNAS |

**Quick connectivity test** from the Proxmox node shell:

```bash
# Replace 192.168.10.50 and your-api-key with real values
curl -sk -H "Authorization: Bearer your-api-key" \
  https://192.168.10.50/api/v2.0/iscsi/global | python3 -m json.tool
```

If this returns JSON with a `basename` field, the API is working. If it returns an HTML login page or a TLS error, you have a connectivity or SSL problem.

### 6.3 Disk Creation Fails with "No iSCSI Portals Found"

**Cause:** The plugin could not match the TrueNAS Host IP (or Portal IP) to any portal configured in TrueNAS iSCSI settings.

**Fix:** In TrueNAS, go to **Shares → iSCSI → Portals** and check what IP the portal is listening on. Either:
- Set the portal to listen on `0.0.0.0` (all interfaces), or
- In Proxmox, edit the storage and set **Portal IP** to the exact IP the TrueNAS portal is listening on

### 6.4 VM Starts but Disk Is Not Accessible / VM Won't Boot

**Cause:** The iSCSI data path is blocked. Even if the plugin successfully created the disk (API path), the VM's QEMU process must open a separate iSCSI TCP connection to TrueNAS.

**Checks:**
1. Confirm TrueNAS iSCSI service is running
2. From the Proxmox node, test TCP connectivity to the iSCSI port:
   ```bash
   nc -zv 192.168.10.50 3260
   ```
3. Check that the initiator group in TrueNAS does not block the Proxmox node's IP
4. Check that the per-VM target in TrueNAS (`proxmox-vm-<vmid>`) has the extent associated with it under **iSCSI → Target/Extent**

### 6.5 API Key Stopped Working After Upgrading TrueNAS SCALE to 25.04

TrueNAS SCALE 25.04 may revoke API keys created under certain conditions during upgrade, and enforces HTTPS for API key authentication.

**Fix:**
1. Log into TrueNAS SCALE → **Credentials → API Keys** → generate a new key
2. In Proxmox: **Datacenter → Storage** → select your TrueNAS storage → **Edit**
3. Paste the new API key into the **API Key** field
4. Ensure **Use SSL** is checked

### 6.6 Disk Size Shown in TrueNAS Is Larger Than What I Entered in Proxmox

This is expected and not an error. Proxmox creates disks in GiB (base-2) but TrueNAS reports sizes in GB (base-10). An 80 GiB disk shows as approximately 85.90 GB in TrueNAS. The disk inside your VM is exactly what you asked for.

### 6.7 TPM State Disk Fails to Create on TrueNAS Storage

TPM state (`tpmstate0`) is a known limitation — this storage type cannot hold TPM state disks. When creating a VM with TPM/Secure Boot, configure a different storage (such as `local-lvm` or NFS) for the `tpmstate0` disk. All other disk types work normally.

---

## 7. Uninstalling

Before uninstalling, remove any storage configurations that use this plugin from Proxmox, and migrate any VM disks off TrueNAS storage. Uninstalling while VMs are still using TrueNAS disks will not delete your data, but Proxmox will lose track of those disks.

### Step 1 — Remove Storage Configurations

In the Proxmox UI: **Datacenter → Storage** → select each TrueNAS storage entry → **Remove**.

### Step 2 — Uninstall the Package

```bash
apt remove truenas-proxmox
```

The removal script:
- Deletes `/usr/share/perl5/PVE/Storage/Custom/TrueNAS.pm`
- Deletes `/usr/share/pve-manager/js/truenas-storage.js`
- Removes the `<script>` tag from `/usr/share/pve-manager/index.html.tpl`
- Restarts `pvedaemon` and `pveproxy`

To also remove install logs:

```bash
apt purge truenas-proxmox
```

### Step 3 — Refresh Your Browser

Hard-refresh the browser after uninstalling. The TrueNAS option will disappear from the Add Storage dropdown.

---

## Getting Help

- GitHub Issues: https://github.com/TheGrandWazoo/truenas-proxmox/issues
- When reporting a bug, include log lines from `journalctl -u pvedaemon | grep -i truenas` and the output of `pveversion`
