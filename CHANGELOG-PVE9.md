# Changelog

All notable changes to the freenas-proxmox plugin for Proxmox VE 9 support.

## [2.0.0-pve9] - 2025-01-13

### Added
- **Complete Proxmox VE 9 compatibility** with architectural changes
- **Automated installation script** (`install-pve9.sh`) for new deployments
- **Compatibility patcher script** (`patch-pve9.sh`) for existing installations
- **Comprehensive error handling** throughout all modules
- **Enhanced API communication** with TrueNAS middleware
- **Improved SSH command execution** with better error reporting
- **Complete method implementations** in FreeNAS.pm module
- **Automatic syntax validation** during installation/patching
- **Service restart automation** with status verification
- **Detailed debug logging** capabilities
- **Professional documentation** with troubleshooting guides

### Fixed
- **Critical LUN 0 falsy handling bug** in `zfs_get_lun_number()` 
  - Changed `if !$guid` to `if !defined $guid`
  - Prevents VM startup failures when disks are on LUN 0
  - Essential fix for PVE 9 compatibility
- **Return format compatibility** between `list_lu` and `zfs_get_lun_number`
  - `list_lu` now returns just LUN number, not formatted string
  - Eliminates parsing errors in VM operations
- **Method dispatch completeness** in FreeNAS.pm
  - Added missing `list_lu`, `list_view`, `list_lun` implementations
  - Fixed parameter handling for all LUN operations
- **Provider integration** in ZFSPlugin.pm
  - Added freenas to provider validation list
  - Implemented freenas LUN command handler
  - Added freenas configuration properties
- **Numeric parameter validation** in `run_freenas_list_view`
  - Ensures LUN parameters are properly validated
  - Prevents crashes from invalid input
- **JSON response parsing** with proper error handling
  - Robust API response validation
  - Graceful failure handling for malformed responses
- **SSH key path construction** for multi-host environments
  - Dynamic SSH key selection based on target host
  - Improved security and flexibility

### Improved
- **Code organization** with clear function separation
- **Error messages** with detailed context information  
- **API call efficiency** with reduced redundant requests
- **Documentation coverage** with comprehensive examples
- **Installation safety** with automatic backups
- **Validation procedures** with syntax checking
- **Service management** with proper restart sequencing

### Changed
- **FreeNAS.pm module architecture** for better maintainability
- **API communication patterns** for improved reliability
- **Error handling strategy** throughout the codebase
- **Installation process** with automated validation steps
- **Configuration validation** with comprehensive checks

### Technical Details

#### Core Bug Fixes
```perl
# Before (broken in PVE 9):
die "could not find lun_number for guid $guid" if !$guid;

# After (PVE 9 compatible):
die "could not find lun_number for guid " . (defined $guid ? $guid : "undef") if !defined $guid;
```

#### Method Implementation
- `run_freenas_list_lu()`: Returns LUN number for volume lookup
- `run_freenas_list_view()`: Returns formatted LUN information  
- `run_freenas_list_lun()`: Returns array of all available LUNs
- `run_freenas_create_lu()`: Creates new iSCSI extent
- `run_freenas_delete_lu()`: Removes iSCSI extent

#### Provider Integration
- Added freenas to ZFSPlugin.pm provider validation
- Implemented freenas LUN command routing
- Added freenas-specific configuration properties

### Migration Notes

#### From Previous Versions
1. **Automatic patching**: Use `patch-pve9.sh` for existing installations
2. **Backup creation**: All original files are automatically backed up
3. **Service restart**: Proxmox services are restarted automatically
4. **Validation**: Syntax and functionality are verified post-patch

#### New Installations
1. **Fresh install**: Use `install-pve9.sh` for new deployments
2. **Dependency management**: All required packages installed automatically
3. **Configuration validation**: Installation process includes verification steps

### Compatibility

#### Supported Versions
- **Proxmox VE**: 9.0+
- **TrueNAS Core**: 13.0+
- **TrueNAS Scale**: 22.12+

#### Tested Configurations
- Proxmox VE 9.0.0 with TrueNAS Core 13.0
- Proxmox VE 9.0.0 with TrueNAS Scale 22.12
- Multiple LUN configurations (0-10+)
- Cloud-init disk support
- VM migration scenarios

### Known Issues
- None currently identified

### Security Considerations
- SSH key-based authentication required
- No passwords stored in configuration files
- Secure API communication via SSH tunnel
- Proper file permissions maintained

---

## Previous Versions

### [1.x] - Previous Releases
- Original freenas-proxmox functionality for Proxmox VE 7-8
- Basic TrueNAS integration
- Manual configuration required
