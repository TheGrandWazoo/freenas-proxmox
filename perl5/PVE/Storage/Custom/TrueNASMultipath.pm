package PVE::Storage::Custom::TrueNASMultipath;

# TrueNAS Multipath Storage Plugin for Proxmox VE
#
# Extends TrueNAS.pm with kernel iSCSI multipath support (iscsiadm + dm-multipath).
# Registers as PVE storage type 'truenas-multipath'.
#
# Requires: truenas-proxmox >= 3.1.0, open-iscsi, multipath-tools
# Auth:     Same Bearer token model as TrueNAS.pm
# Path:     /dev/mapper/<wwid> instead of iscsi:// — QEMU uses the block device directly

use strict;
use warnings;

use PVE::Storage::Custom::TrueNAS;
use base qw(PVE::Storage::Custom::TrueNAS);

# ── Plugin identity ───────────────────────────────────────────────────────────

sub type { return 'truenas-multipath'; }

sub plugindata {
    return {
        content => [ { images => 1 }, { images => 1 } ],
        format  => [ { raw    => 1 }, 'raw' ],
    };
}

# ── Config properties (extends parent) ───────────────────────────────────────

sub properties {
    my $props = PVE::Storage::Custom::TrueNAS::properties();
    $props->{truenas_portals} = {
        description => "Comma-separated iSCSI portal IP addresses for multipath "
                     . "(e.g. '172.31.69.91,192.168.69.91'). Each portal is logged "
                     . "into separately; dm-multipath aggregates the sessions.",
        type        => 'string',
    };
    return $props;
}

sub options {
    my $opts = PVE::Storage::Custom::TrueNAS::options();
    $opts->{truenas_portals} = { optional => 0 };
    return $opts;
}

# ── Private helpers ───────────────────────────────────────────────────────────

# Parse truenas_portals into a list of IP strings.
sub _portals {
    my ($scfg) = @_;
    return grep { length } split /\s*,\s*/, ($scfg->{truenas_portals} // '');
}

# Convert TrueNAS NAA string (e.g. "0x6589cfc...") to the dm-multipath WWID
# used in /dev/mapper/ (e.g. "36589cfc...").
sub _naa_to_wwid {
    my ($naa) = @_;
    $naa =~ s/^0x//i;
    return "3$naa";
}

# Run an iscsiadm command, returning (exit_code, output).
# Suppresses errors that indicate a session already exists.
sub _iscsiadm {
    my (@args) = @_;
    my $out = '';
    open(my $fh, '-|', 'iscsiadm', @args, '2>&1')
        or return (1, "failed to exec iscsiadm: $!");
    $out = do { local $/; <$fh> };
    close $fh;
    my $rc = $? >> 8;
    return ($rc, $out);
}

# Wait up to $timeout seconds for a block device path to appear.
sub _wait_for_device {
    my ($path, $timeout) = @_;
    $timeout //= 30;
    while ($timeout-- > 0) {
        return 1 if -b $path;
        sleep 1;
    }
    return 0;
}

# ── Path — block device via dm-multipath ─────────────────────────────────────

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    PVE::Storage::Custom::TrueNAS::_resolve_token($storeid, $scfg);

    my $ext = PVE::Storage::Custom::TrueNAS::_find_extent($scfg, $volname);
    die "Volume '$volname' has no iSCSI extent on $scfg->{truenas_host}.\n" unless $ext;

    my $wwid = _naa_to_wwid($ext->{naa})
        or die "Volume '$volname' has no NAA/WWID on $scfg->{truenas_host}.\n";

    return ("/dev/mapper/$wwid", $ext->{lun_id}, $storeid);
}

# ── qemu_blockdev_options — not used (path returns a block device) ────────────

# The base class qemu_blockdev_options builds an iscsi:// blockdev.
# For multipath we return undef so PVE uses path() instead.
sub qemu_blockdev_options { return; }

# ── activate_volume — login via all portals, wait for mapper device ───────────

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    PVE::Storage::Custom::TrueNAS::_resolve_token($storeid, $scfg);

    my $ext = PVE::Storage::Custom::TrueNAS::_find_extent($scfg, $volname);
    die "Volume '$volname' has no iSCSI extent on $scfg->{truenas_host}.\n" unless $ext;
    die "Volume '$volname' is not mapped to any iSCSI target.\n"
        unless defined $ext->{target_id};

    my $t   = PVE::Storage::Custom::TrueNAS::_api($scfg, 'GET',
                  "/iscsi/target/id/$ext->{target_id}") // {};
    my $iqn = PVE::Storage::Custom::TrueNAS::_basename($scfg) . ":$t->{name}";

    my $wwid = _naa_to_wwid($ext->{naa})
        or die "Volume '$volname' has no NAA/WWID.\n";
    my $mapper = "/dev/mapper/$wwid";

    return if -b $mapper;    # already active

    my @portals = _portals($scfg);
    die "No portals configured — set truenas_portals in storage config.\n" unless @portals;

    PVE::Storage::Custom::TrueNAS::_log('info',
        "multipath activate: $volname  iqn=$iqn  wwid=$wwid  portals=" . join(',', @portals));

    for my $ip (@portals) {
        my $portal = "$ip:3260";

        # Ensure node entry exists
        _iscsiadm('-m', 'node', '-T', $iqn, '-p', $portal, '-o', 'new');

        # Login — ISCSI_ERR_SESS_EXISTS (15) is fine
        my ($rc, $out) = _iscsiadm('-m', 'node', '-T', $iqn, '-p', $portal, '--login');
        if ($rc && $rc != 15) {
            die "iscsiadm login to $portal failed (rc=$rc): $out\n";
        }
    }

    # Tell multipathd to rescan now
    system('multipathd', 'reconfigure') if -x '/usr/sbin/multipathd';
    system('multipath') if !-b $mapper;

    unless (_wait_for_device($mapper, 30)) {
        die "Multipath device $mapper did not appear after 30s. "
          . "Check that multipathd is running and multipath.conf includes TrueNAS devices.\n";
    }

    PVE::Storage::Custom::TrueNAS::_log('info', "multipath activate: $mapper ready");
    return;
}

# ── deactivate_volume — logout from all portals, flush mapper device ──────────

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    PVE::Storage::Custom::TrueNAS::_resolve_token($storeid, $scfg);

    my $ext = PVE::Storage::Custom::TrueNAS::_find_extent($scfg, $volname);
    return unless $ext && defined $ext->{target_id};

    my $t   = PVE::Storage::Custom::TrueNAS::_api($scfg, 'GET',
                  "/iscsi/target/id/$ext->{target_id}") // {};
    my $iqn = PVE::Storage::Custom::TrueNAS::_basename($scfg) . ":$t->{name}";

    my $wwid   = _naa_to_wwid($ext->{naa} // '');
    my $mapper = $wwid ? "/dev/mapper/$wwid" : undef;

    # Flush multipath device first
    if ($mapper && -b $mapper) {
        system('multipath', '-f', $wwid);
    }

    for my $ip (_portals($scfg)) {
        my $portal = "$ip:3260";
        _iscsiadm('-m', 'node', '-T', $iqn, '-p', $portal, '--logout');
        _iscsiadm('-m', 'node', '-T', $iqn, '-p', $portal, '-o', 'delete');
    }

    PVE::Storage::Custom::TrueNAS::_log('info', "multipath deactivate: $volname done");
    return;
}

1;
