# FreeNAS-Proxmox Plugin for Proxmox VE 9

This repository provides **complete Proxmox VE 9 compatibility** for the freenas-proxmox plugin, enabling seamless integration between Proxmox VE 9 and FreeNAS/TrueNAS systems for iSCSI storage management.

## 🚀 What's New in v2.0.0-pve9

- **Full Proxmox VE 9 compatibility** with architectural changes
- **Critical LUN 0 handling fix** - resolves VM startup failures 
- **Improved error handling** and robust API communication
- **Enhanced FreeNAS.pm module** with complete method implementations
- **Automatic installation and patching scripts** for easy deployment
- **Comprehensive testing** and validation

## 🎯 Key Features

- **Complete iSCSI LUN management** through TrueNAS middleware API
- **Support for all LUN numbers** including LUN 0 (critical fix for PVE 9)
- **Cloud-init disk support** on TrueNAS storage
- **Automatic VM disk provisioning** and management
- **TrueNAS Core 13.0+ and TrueNAS Scale 22.12+ compatibility**
- **SSH-based secure communication** with TrueNAS systems

## 📋 Requirements

- **Proxmox VE 9.0+**
- **TrueNAS Core 13.0+ or TrueNAS Scale 22.12+**
- **SSH key authentication** between Proxmox and TrueNAS
- **iSCSI target configured** on TrueNAS
- **Root access** on Proxmox VE node

## 🔧 Installation

### New Installations

For new Proxmox VE 9 systems without existing freenas-proxmox plugin:

```bash
# Download the installer
wget https://raw.githubusercontent.com/TheGrandWazoo/freenas-proxmox/pve9-support/install-pve9.sh

# Make executable and run
chmod +x install-pve9.sh
sudo ./install-pve9.sh
```

### Existing Installations

For Proxmox VE 9 systems with existing freenas-proxmox plugin that needs PVE 9 fixes:

```bash
# Download the patcher
wget https://raw.githubusercontent.com/TheGrandWazoo/freenas-proxmox/pve9-support/patch-pve9.sh

# Make executable and run  
chmod +x patch-pve9.sh
sudo ./patch-pve9.sh
```

## ⚙️ Configuration

### 1. SSH Key Setup

Configure SSH key authentication between Proxmox and TrueNAS:

```bash
# Create SSH key directory
mkdir -p /etc/pve/priv/zfs

# Generate SSH key (replace TRUENAS_IP with your TrueNAS IP)
ssh-keygen -f /etc/pve/priv/zfs/TRUENAS_IP_id_rsa

# Copy public key to TrueNAS
ssh-copy-id -i /etc/pve/priv/zfs/TRUENAS_IP_id_rsa.pub root@TRUENAS_IP

# Test connectivity
ssh -i /etc/pve/priv/zfs/TRUENAS_IP_id_rsa root@TRUENAS_IP "midclt call system.info"
```

### 2. TrueNAS iSCSI Configuration

Ensure your TrueNAS system has:
- **iSCSI service enabled**
- **Portal configured** with appropriate network settings
- **Target created** for Proxmox access
- **Authentication configured** (CHAP recommended)

### 3. Proxmox Storage Configuration

Add FreeNAS storage through the Proxmox web interface:

1. Navigate to **Datacenter → Storage → Add**
2. Select **"ZFS over iSCSI"** as storage type
3. Configure the following:
   - **ID**: `freenas-storage` (or your preferred name)
   - **Portal**: Your TrueNAS IP address
   - **Target**: Your TrueNAS iSCSI target IQN
   - **Pool**: ZFS pool name on TrueNAS
   - **Block size**: `8k` (recommended)
   - **iSCSI provider**: `freenas`
   - **FreeNAS API host**: Your TrueNAS IP address  
   - **FreeNAS user**: `root`
   - **FreeNAS password**: Your TrueNAS root password
   - **Content**: Select `Disk image` and `Container` as needed

## 🐛 Critical Fixes Applied

### LUN 0 Handling Fix

**Problem**: Proxmox VE 9 had a critical bug where LUN 0 was treated as a falsy value, causing VM startup failures.

**Solution**: Fixed the condition check from `if !$guid` to `if !defined $guid` in ZFSPlugin.pm.

**Impact**: VMs with disks on LUN 0 can now start successfully.

### Return Format Compatibility

**Problem**: Function return formats between `list_lu` and `zfs_get_lun_number` were incompatible.

**Solution**: Standardized return formats to ensure proper data flow between functions.

**Impact**: Eliminates "unknown method" and parsing errors.

### Complete Method Implementation

**Problem**: Missing or incomplete LUN command methods in FreeNAS.pm.

**Solution**: Implemented all required methods with proper error handling.

**Impact**: Full iSCSI LUN management functionality.

## 🧪 Testing

After installation, test the integration:

### 1. Verify Storage Recognition

```bash
# Check storage status
pvesm status

# List available storage
pvesm list freenas-storage
```

### 2. Create Test VM

1. Create a new VM through Proxmox web interface
2. Select your FreeNAS storage for the disk
3. Start the VM and verify it boots correctly

### 3. Test Cloud-init Support

Create a VM with cloud-init enabled and verify the cloud-init disk is properly created on TrueNAS storage.

## 🔍 Troubleshooting

### Common Issues

**VM fails to start with "Could not find lu_name" error:**
- Ensure the patcher was applied correctly
- Check that FreeNAS storage is properly configured
- Verify SSH connectivity to TrueNAS

**iSCSI connection failures:**
- Verify TrueNAS iSCSI service is running
- Check network connectivity between Proxmox and TrueNAS
- Ensure proper authentication configuration

**Storage not appearing in Proxmox:**
- Verify ZFSPlugin.pm includes freenas provider support
- Check Proxmox service status: `systemctl status pvedaemon`
- Review logs: `/var/log/daemon.log`

### Debug Mode

To enable detailed debug logging:

```bash
# Enable debug logging
export PVE_DEBUG_STORAGE=1

# Restart pvedaemon
systemctl restart pvedaemon

# Check logs
tail -f /var/log/daemon.log | grep -i freenas
```

## 📝 Changelog

### v2.0.0-pve9 (2025-01-13)

**Added:**
- Complete Proxmox VE 9 compatibility
- Automated installation and patching scripts
- Comprehensive error handling and validation
- Enhanced documentation and troubleshooting guides

**Fixed:**
- Critical LUN 0 falsy value handling (prevents VM startup failures)
- Return format compatibility between plugin functions
- Provider integration in ZFSPlugin.pm
- Method implementations in FreeNAS.pm

**Improved:**
- SSH command execution and error handling
- API response parsing and validation
- Code organization and maintainability

## 🤝 Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Test your changes thoroughly
4. Submit a pull request with detailed description

## 📄 License

This project is licensed under the GPL-3.0 License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- Original freenas-proxmox project by [TheGrandWazoo](https://github.com/TheGrandWazoo)
- Proxmox VE community for testing and feedback
- TrueNAS community for API documentation and support

## 📞 Support

- **GitHub Issues**: [Report bugs and request features](https://github.com/TheGrandWazoo/freenas-proxmox/issues)
- **Proxmox Forum**: [Community discussions](https://forum.proxmox.com/)
- **TrueNAS Forum**: [TrueNAS-specific questions](https://www.truenas.com/community/)

---

**⚠️ Important**: Always backup your Proxmox configuration before applying these patches. While thoroughly tested, modifications to system files should be approached with caution in production environments.
