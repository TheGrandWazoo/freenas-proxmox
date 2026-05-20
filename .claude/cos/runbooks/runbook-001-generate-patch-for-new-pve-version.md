# Runbook: Generate a Patch for a New Proxmox VE Version

When Proxmox VE releases an update that breaks the existing patches, follow these steps.

## Prerequisites

- A Proxmox VE node (or VM) running the new version
- SSH access to that node
- The current `FreeNAS.pm` changes you want to apply

## Steps

### 1. Copy the original files from the PVE node

```bash
# On your dev machine
PVE_HOST=your-proxmox-node
PVE_VER=$(ssh root@$PVE_HOST "dpkg-query --showformat='\${Version}' --show pve-manager")

mkdir -p stable-8/originals

scp root@$PVE_HOST:/usr/share/perl5/PVE/Storage/ZFSPlugin.pm \
    stable-8/perl5/PVE/Storage/ZFSPlugin.pm.orig

scp root@$PVE_HOST:/usr/share/pve-manager/js/pvemanagerlib.js \
    stable-8/pve-manager/js/pvemanagerlib.js.orig

scp root@$PVE_HOST:/usr/share/pve-docs/api-viewer/apidoc.js \
    stable-8/pve-docs/api-viewer/apidoc.js.orig
```

### 2. Apply the desired modifications

Work on copies of the `.orig` files:

```bash
cp stable-8/perl5/PVE/Storage/ZFSPlugin.pm.orig /tmp/ZFSPlugin.pm
# ... make your changes manually or apply the known modifications ...
```

### 3. Generate the patch

```bash
diff -u stable-8/perl5/PVE/Storage/ZFSPlugin.pm.orig /tmp/ZFSPlugin.pm \
    > stable-8/perl5/PVE/Storage/ZFSPlugin-${PVE_VER}.pm.patch

# Do the same for the other files
```

### 4. Test the patch

```bash
# On the PVE node or a copy:
patch --dry-run -p0 /usr/share/perl5/PVE/Storage/ZFSPlugin.pm \
    < stable-8/perl5/PVE/Storage/ZFSPlugin-${PVE_VER}.pm.patch
```

### 5. Update the postinst version map

In `packaging/DEBIAN/postinst`, update the version-to-patch-file mapping to include the new PVE version.

### 6. Update the default `.patch` symlink or file

The `postinst` selects a patch file based on the installed PVE version. Make sure the new patch is in the version map.

## Notes

- The JS files are large (pvemanagerlib.js is several MB); patches are usually small diffs around the iSCSI provider section
- Use `--ignore-whitespace` with patch to handle indentation differences
- Test with `patch --dry-run` before committing
