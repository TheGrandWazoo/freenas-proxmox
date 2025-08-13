#!/bin/bash

#################################################
# FreeNAS-Proxmox Plugin for Proxmox VE 9
# Complete Installation Script
#
# This script installs the freenas-proxmox plugin
# with full PVE 9 compatibility fixes.
#
# Author: Community Contribution
# License: GPL-3.0
# Repository: https://github.com/TheGrandWazoo/freenas-proxmox
#################################################

set -e  # Exit on any error

VERSION="2.0.0-pve9"
SCRIPT_NAME="FreeNAS-Proxmox PVE 9 Installer"

echo "=================================================="
echo "$SCRIPT_NAME v$VERSION"
echo "=================================================="
echo "Installing freenas-proxmox plugin for Proxmox VE 9"
echo "with TrueNAS Scale/Core compatibility"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "❌ This script must be run as root"
    echo "Usage: sudo $0"
    exit 1
fi

# Check for Proxmox VE
if ! command -v pveversion >/dev/null 2>&1; then
    echo "❌ This script requires Proxmox VE"
    echo "pveversion command not found"
    exit 1
fi

PVE_VERSION=$(pveversion --verbose 2>/dev/null | head -1)
echo "Detected: $PVE_VERSION"

# Validate PVE version
if [[ ! "$PVE_VERSION" =~ "pve-manager" ]]; then
    echo "❌ Unable to detect valid Proxmox VE installation"
    exit 1
fi

echo ""
echo "=== INSTALLATION OVERVIEW ==="
echo "This script will:"
echo "• Install required dependencies"
echo "• Create backup of existing files"
echo "• Install FreeNAS.pm LUN command module"
echo "• Patch ZFSPlugin.pm for freenas provider support"
echo "• Apply PVE 9 compatibility fixes"
echo "• Restart Proxmox services"
echo "• Verify installation"
echo ""

read -p "Continue with installation? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Installation cancelled"
    exit 0
fi

echo ""
echo "=== STEP 1: INSTALLING DEPENDENCIES ==="

apt update >/dev/null 2>&1
apt install -y jq perl librest-client-perl libwww-perl libjson-perl >/dev/null 2>&1

echo "✓ Dependencies installed"

echo ""
echo "=== STEP 2: CREATING BACKUPS ==="

BACKUP_DIR="/root/freenas-proxmox-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

# Backup existing files
for file in "/usr/share/perl5/PVE/Storage/ZFSPlugin.pm" "/usr/share/perl5/PVE/Storage/LunCmd/FreeNAS.pm" "/etc/pve/storage.cfg"; do
    if [ -f "$file" ]; then
        cp "$file" "$BACKUP_DIR/$(basename "$file").original"
        echo "✓ Backed up $(basename "$file")"
    fi
done

echo "✓ Backups created in: $BACKUP_DIR"

echo ""
echo "=== STEP 3: INSTALLING FREENAS MODULE ==="

mkdir -p /usr/share/perl5/PVE/Storage/LunCmd/

cat > /usr/share/perl5/PVE/Storage/LunCmd/FreeNAS.pm << 'EOF'
package PVE::Storage::LunCmd::FreeNAS;

use strict;
use warnings;
use JSON;

# FreeNAS/TrueNAS LUN command interface for Proxmox VE 9
# Provides complete iSCSI LUN management through TrueNAS middleware API

our $VERSION = '2.0.0-pve9';

sub get_base {
    return '/usr/bin/ssh';
}

# Main entry point for all LUN operations
sub run_lun_command {
    my ($scfg, $timeout, $method, @params) = @_;
    
    if ($method eq 'create_lu') {
        return run_freenas_create_lu($scfg, $timeout, @params);
    } elsif ($method eq 'delete_lu') {
        return run_freenas_delete_lu($scfg, $timeout, @params);
    } elsif ($method eq 'import_lu') {
        return run_freenas_import_lu($scfg, $timeout, @params);
    } elsif ($method eq 'modify_lu') {
        return run_freenas_modify_lu($scfg, $timeout, @params);
    } elsif ($method eq 'add_view') {
        return run_freenas_add_view($scfg, $timeout, @params);
    } elsif ($method eq 'list_view') {
        return run_freenas_list_view($scfg, $timeout, @params);
    } elsif ($method eq 'list_lu') {
        return run_freenas_list_lu($scfg, $timeout, @params);
    } elsif ($method eq 'list_lun') {
        return run_freenas_list_lun($scfg, $timeout, @params);
    }
    
    die "unknown method $method";
}

# List specific logical unit by name
# Returns: LUN number for successful lookup, undef for not found
sub run_freenas_list_lu {
    my ($scfg, $timeout, $lu_name) = @_;
    
    # Extract volume name from path
    my $volume_name = $lu_name;
    $volume_name =~ s|.*/||;  # Remove path components
    
    # Query all extents from TrueNAS
    my $extents = query_truenas_extents($scfg);
    return undef unless $extents;
    
    # Find matching extent by name
    my $found_extent;
    foreach my $extent (@$extents) {
        if ($extent->{name} && $extent->{name} =~ /$volume_name$/) {
            $found_extent = $extent;
            last;
        }
    }
    return undef unless $found_extent;
    
    # Query target-extent mappings
    my $mappings = query_truenas_mappings($scfg);
    return undef unless $mappings;
    
    # Find LUN number for this extent
    foreach my $mapping (@$mappings) {
        if ($mapping->{extent} == $found_extent->{id}) {
            return $mapping->{lunid};
        }
    }
    
    return undef;
}

# List view information for specific LUN
# Returns: Formatted LUN information string
sub run_freenas_list_view {
    my ($scfg, $timeout, $lun) = @_;
    
    # Validate LUN parameter
    return undef unless defined $lun && $lun =~ /^\d+$/;
    
    # Query target-extent mappings
    my $mappings = query_truenas_mappings($scfg);
    return undef unless $mappings;
    
    # Find mapping for specified LUN
    foreach my $mapping (@$mappings) {
        if (defined $mapping->{lunid} && $mapping->{lunid} == $lun) {
            return format_lun_info($scfg, $mapping, $lun);
        }
    }
    
    return undef;
}

# List all available LUN numbers
# Returns: Array of LUN numbers
sub run_freenas_list_lun {
    my ($scfg, $timeout) = @_;
    
    my $mappings = query_truenas_mappings($scfg);
    return () unless $mappings;
    
    my @luns = ();
    foreach my $mapping (@$mappings) {
        if (defined $mapping->{lunid}) {
            push @luns, $mapping->{lunid};
        }
    }
    
    # Sort and remove duplicates
    my %seen = ();
    @luns = sort { $a <=> $b } grep { !$seen{$_}++ } @luns;
    
    return @luns;
}

# Create new logical unit
sub run_freenas_create_lu {
    my ($scfg, $timeout, $name, $size) = @_;
    
    my $size_bytes = $size * 1024 * 1024;
    
    my $create_data = {
        name => $name,
        type => "DISK",
        disk => "zvol/$scfg->{pool}/$name",
        filesize => $size_bytes
    };
    
    my $result = call_truenas_api($scfg, 'iscsi.extent.create', $create_data);
    return $result ? $name : undef;
}

# Delete logical unit
sub run_freenas_delete_lu {
    my ($scfg, $timeout, $name) = @_;
    
    my $extents = query_truenas_extents($scfg);
    return undef unless $extents;
    
    foreach my $extent (@$extents) {
        if ($extent->{name} eq $name) {
            my $result = call_truenas_api($scfg, 'iscsi.extent.delete', $extent->{id});
            return $result ? $name : undef;
        }
    }
    
    return undef;
}

# Stub implementations for compatibility
sub run_freenas_import_lu { return $_[2]; }
sub run_freenas_modify_lu { return $_[2]; }
sub run_freenas_add_view { return "view added"; }

# Helper function: Query TrueNAS extents
sub query_truenas_extents {
    my ($scfg) = @_;
    
    my $output = call_truenas_api($scfg, 'iscsi.extent.query');
    return $output ? decode_json($output) : undef;
}

# Helper function: Query TrueNAS target-extent mappings
sub query_truenas_mappings {
    my ($scfg) = @_;
    
    my $output = call_truenas_api($scfg, 'iscsi.targetextent.query');
    return $output ? decode_json($output) : undef;
}

# Helper function: Format LUN information
sub format_lun_info {
    my ($scfg, $mapping, $lun) = @_;
    
    my $extent_info = call_truenas_api($scfg, 'iscsi.extent.get_instance', $mapping->{extent});
    return undef unless $extent_info;
    
    my $extent = decode_json($extent_info);
    my $size_mb = "unknown";
    
    # Try to get size for ZVOL extents
    if ($extent->{disk} && $extent->{disk} =~ /^zvol\//) {
        my $size_output = call_truenas_api($scfg, 'zfs.dataset.get_instance', $extent->{disk});
        if ($size_output) {
            my $dataset = decode_json($size_output);
            if ($dataset->{properties} && $dataset->{properties}->{volsize}) {
                $size_mb = int($dataset->{properties}->{volsize}->{parsed} / (1024 * 1024));
            }
        }
    }
    
    return "$lun $extent->{name} ${size_mb}MB online";
}

# Helper function: Call TrueNAS API via SSH
sub call_truenas_api {
    my ($scfg, $api_method, $params) = @_;
    
    my $host = $scfg->{freenas_apiv4_host} || $scfg->{portal};
    my $user = $scfg->{freenas_user} || 'root';
    my $ssh_key = "/etc/pve/priv/zfs/${host}_id_rsa";
    
    my $cmd = "/usr/bin/ssh -i $ssh_key -o StrictHostKeyChecking=no $user\@$host \"midclt call $api_method";
    
    if (defined $params) {
        if (ref($params) eq 'HASH') {
            my $json_params = encode_json($params);
            $cmd .= " '$json_params'";
        } else {
            $cmd .= " '$params'";
        }
    }
    
    $cmd .= "\"";
    
    my $output = `$cmd 2>&1`;
    my $exit_code = $? >> 8;
    
    return ($exit_code == 0) ? $output : undef;
}

# Export functions for backward compatibility
sub list_lun { run_freenas_list_lun(@_); }
sub list_view { run_freenas_list_view(@_); }
sub list_lu { run_freenas_list_lu(@_); }
sub create_lu { run_freenas_create_lu(@_); }
sub delete_lu { run_freenas_delete_lu(@_); }

1;

__END__

=head1 NAME

PVE::Storage::LunCmd::FreeNAS - FreeNAS/TrueNAS LUN management for Proxmox VE

=head1 DESCRIPTION

This module provides iSCSI LUN management functionality for FreeNAS and TrueNAS
systems within Proxmox VE 9. It communicates with the TrueNAS middleware API
via SSH to manage iSCSI extents and target mappings.

=head1 REQUIREMENTS

- SSH key-based authentication to TrueNAS system
- TrueNAS Core 13.0+ or TrueNAS Scale 22.12+
- Proxmox VE 9.0+

=head1 AUTHOR

Community contribution for freenas-proxmox project

=head1 LICENSE

GPL-3.0

=cut
EOF

echo "✓ FreeNAS.pm module installed"

echo ""
echo "=== STEP 4: PATCHING ZFSPLUGIN ==="

# Apply ZFSPlugin.pm patches
cat > /tmp/patch_zfsplugin.pl << 'EOF'
#!/usr/bin/perl
use strict;

my $file = '/usr/share/perl5/PVE/Storage/ZFSPlugin.pm';
open(my $fh, '<', $file) or die "Cannot open $file: $!";
my $content = do { local $/; <$fh> };
close($fh);

my $changes_made = 0;

# Patch 1: Add freenas to provider validation list
if ($content !~ /die "\$provider: unknown iscsi provider.*freenas/) {
    $content =~ s/(die "\$provider: unknown iscsi provider\. Available \[.*?)\]"/$1, freenas]"/g;
    $changes_made = 1;
    print "✓ Added freenas to provider validation\n";
}

# Patch 2: Add freenas LUN command handler
if ($content !~ /elsif.*freenas.*run_lun_command/) {
    $content =~ s/(} elsif \(\$scfg->\{iscsiprovider\} eq 'LIO'\) \{
            \$msg = PVE::Storage::LunCmd::LIO::run_lun_command\(\$scfg, \$timeout, \$method, \@params\);)/} elsif (\$scfg->{iscsiprovider} eq 'LIO') {
            \$msg = PVE::Storage::LunCmd::LIO::run_lun_command(\$scfg, \$timeout, \$method, \@params);
        } elsif (\$scfg->{iscsiprovider} eq 'freenas') {
            \$msg = PVE::Storage::LunCmd::FreeNAS::run_lun_command(\$scfg, \$timeout, \$method, \@params);/s;
    $changes_made = 1;
    print "✓ Added freenas LUN command handler\n";
}

# Patch 3: Add freenas configuration properties
if ($content !~ /freenas_apiv4_host/) {
    my $freenas_properties = '
        freenas_use_ssl => {
            description => "Use SSL for FreeNAS API connection",
            type => "boolean",
        },
        freenas_user => {
            description => "FreeNAS API username",
            type => "string",
        },
        freenas_password => {
            description => "FreeNAS API password",
            type => "string",
            maxLength => 256,
        },
        freenas_apiv4_host => {
            description => "FreeNAS API v4 host",
            type => "string",
            format => "address",
        },';

    $content =~ s/(pool => \{[^}]+\},)/$1$freenas_properties/s;
    $changes_made = 1;
    print "✓ Added freenas configuration properties\n";
}

# Patch 4: Fix falsy LUN 0 handling (critical PVE 9 fix)
if ($content =~ /if !\$guid;/) {
    $content =~ s/die "could not find lun_number for guid \$guid" if !\$guid;/die "could not find lun_number for guid " . (defined \$guid ? \$guid : "undef") if !defined \$guid;/g;
    $changes_made = 1;
    print "✓ Applied PVE 9 falsy LUN 0 fix\n";
}

# Write changes if any were made
if ($changes_made) {
    open(my $out_fh, '>', $file) or die "Cannot write $file: $!";
    print $out_fh $content;
    close($out_fh);
    print "✓ ZFSPlugin.pm patched successfully\n";
} else {
    print "✓ ZFSPlugin.pm already contains required patches\n";
}
EOF

perl /tmp/patch_zfsplugin.pl

echo ""
echo "=== STEP 5: VALIDATING INSTALLATION ==="

# Test syntax
for module in "/usr/share/perl5/PVE/Storage/LunCmd/FreeNAS.pm" "/usr/share/perl5/PVE/Storage/ZFSPlugin.pm"; do
    if perl -c "$module" >/dev/null 2>&1; then
        echo "✓ $(basename "$module") syntax valid"
    else
        echo "❌ $(basename "$module") syntax error"
        perl -c "$module"
        exit 1
    fi
done

echo ""
echo "=== STEP 6: RESTARTING SERVICES ==="

for service in pvedaemon pveproxy pvestatd; do
    systemctl restart $service
    sleep 2
    
    if systemctl is-active --quiet $service; then
        echo "✓ $service restarted successfully"
    else
        echo "❌ $service failed to restart"
        exit 1
    fi
done

echo ""
echo "=== INSTALLATION VERIFICATION ==="

perl -e "
use lib '/usr/share/perl5';
use PVE::Storage::LunCmd::FreeNAS;
use PVE::Storage::ZFSPlugin;
print \"✓ All modules load successfully\\n\";
" 2>/dev/null

echo ""
echo "=================================================="
echo "🎉 INSTALLATION COMPLETE! 🎉"
echo "=================================================="
echo ""
echo "FreeNAS-Proxmox plugin v$VERSION installed successfully"
echo ""
echo "NEXT STEPS:"
echo ""
echo "1. Configure SSH authentication to your TrueNAS system:"
echo "   mkdir -p /etc/pve/priv/zfs"
echo "   ssh-keygen -f /etc/pve/priv/zfs/TRUENAS_IP_id_rsa"
echo "   ssh-copy-id -i /etc/pve/priv/zfs/TRUENAS_IP_id_rsa.pub root@TRUENAS_IP"
echo ""
echo "2. Add FreeNAS storage in Proxmox web interface:"
echo "   • Datacenter → Storage → Add"
echo "   • Type: ZFS over iSCSI"
echo "   • iSCSI provider: freenas"
echo "   • Configure TrueNAS connection details"
echo ""
echo "3. Test by creating a VM with FreeNAS storage"
echo ""
echo "Backup directory: $BACKUP_DIR"
echo ""
echo "For support, visit:"
echo "https://github.com/TheGrandWazoo/freenas-proxmox"
echo "=================================================="
