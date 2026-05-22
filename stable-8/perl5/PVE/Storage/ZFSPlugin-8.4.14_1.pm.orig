package PVE::Storage::ZFSPlugin;

use strict;
use warnings;
use IO::File;
use POSIX qw(ENOENT);
use PVE::Tools qw(run_command);
use PVE::Storage::ZFSPoolPlugin;
use PVE::RESTEnvironment qw(log_warn);
use PVE::RPCEnvironment;

use base qw(PVE::Storage::ZFSPoolPlugin);
use PVE::Storage::LunCmd::Comstar;
use PVE::Storage::LunCmd::Istgt;
use PVE::Storage::LunCmd::Iet;
use PVE::Storage::LunCmd::LIO;

my @ssh_opts = ('-o', 'BatchMode=yes');
my @ssh_cmd = ('/usr/bin/ssh', @ssh_opts);
my $id_rsa_path = '/etc/pve/priv/zfs';

my $lun_cmds = {
    create_lu => 1,
    delete_lu => 1,
    import_lu => 1,
    modify_lu => 1,
    add_view => 1,
    list_view => 1,
    list_lu => 1,
};

my $zfs_unknown_scsi_provider = sub {
    my ($provider) = @_;

    die "$provider: unknown iscsi provider. Available [comstar, istgt, iet, LIO]";
};

my $zfs_get_base = sub {
    my ($scfg) = @_;

    if ($scfg->{iscsiprovider} eq 'comstar') {
        return PVE::Storage::LunCmd::Comstar::get_base($scfg);
    } elsif ($scfg->{iscsiprovider} eq 'istgt') {
        return PVE::Storage::LunCmd::Istgt::get_base($scfg);
    } elsif ($scfg->{iscsiprovider} eq 'iet') {
        return PVE::Storage::LunCmd::Iet::get_base($scfg);
    } elsif ($scfg->{iscsiprovider} eq 'LIO') {
        return PVE::Storage::LunCmd::LIO::get_base($scfg);
    } else {
        $zfs_unknown_scsi_provider->($scfg->{iscsiprovider});
    }
};

sub zfs_request {
    my ($class, $scfg, $timeout, $method, @params) = @_;

    $timeout = PVE::RPCEnvironment->is_worker() ? 60 * 60 : 10
        if !$timeout;

    my $msg = '';

    if ($lun_cmds->{$method}) {
        if ($scfg->{iscsiprovider} eq 'comstar') {
            $msg =
                PVE::Storage::LunCmd::Comstar::run_lun_command($scfg, $timeout, $method, @params);
        } elsif ($scfg->{iscsiprovider} eq 'istgt') {
            $msg = PVE::Storage::LunCmd::Istgt::run_lun_command($scfg, $timeout, $method, @params);
        } elsif ($scfg->{iscsiprovider} eq 'iet') {
            $msg = PVE::Storage::LunCmd::Iet::run_lun_command($scfg, $timeout, $method, @params);
        } elsif ($scfg->{iscsiprovider} eq 'LIO') {
            $msg = PVE::Storage::LunCmd::LIO::run_lun_command($scfg, $timeout, $method, @params);
        } else {
            $zfs_unknown_scsi_provider->($scfg->{iscsiprovider});
        }
    } else {

        my $target = 'root@' . $scfg->{portal};

        my $cmd = [@ssh_cmd, '-i', "$id_rsa_path/$scfg->{portal}_id_rsa", $target];

        if ($method eq 'zpool_list') {
            push @$cmd, 'zpool', 'list';
        } else {
            push @$cmd, 'zfs', $method;
        }

        push @$cmd, @params;

        my $output = sub {
            my $line = shift;
            $msg .= "$line\n";
        };

        run_command($cmd, outfunc => $output, timeout => $timeout);
    }

    return $msg;
}

sub zfs_get_lu_name {
    my ($class, $scfg, $zvol) = @_;

    my $base = $zfs_get_base->($scfg);

    $zvol = ($class->parse_volname($zvol))[1];

    my $object = ($zvol =~ /^.+\/.+/) ? "$base/$zvol" : "$base/$scfg->{pool}/$zvol";

    my $lu_name = $class->zfs_request($scfg, undef, 'list_lu', $object);

    return $lu_name if $lu_name;

    die "Could not find lu_name for zvol $zvol";
}

sub zfs_add_lun_mapping_entry {
    my ($class, $scfg, $zvol, $guid) = @_;

    if (!defined($guid)) {
        $guid = $class->zfs_get_lu_name($scfg, $zvol);
    }

    $class->zfs_request($scfg, undef, 'add_view', $guid);
}

sub zfs_delete_lu {
    my ($class, $scfg, $zvol) = @_;

    my $guid = $class->zfs_get_lu_name($scfg, $zvol);

    $class->zfs_request($scfg, undef, 'delete_lu', $guid);
}

sub zfs_create_lu {
    my ($class, $scfg, $zvol) = @_;

    my $base = $zfs_get_base->($scfg);
    my $guid = $class->zfs_request($scfg, undef, 'create_lu', "$base/$scfg->{pool}/$zvol");

    return $guid;
}

sub zfs_import_lu {
    my ($class, $scfg, $zvol) = @_;

    my $base = $zfs_get_base->($scfg);
    $class->zfs_request($scfg, undef, 'import_lu', "$base/$scfg->{pool}/$zvol");
}

sub zfs_resize_lu {
    my ($class, $scfg, $zvol, $size) = @_;

    my $guid = $class->zfs_get_lu_name($scfg, $zvol);

    $class->zfs_request($scfg, undef, 'modify_lu', "${size}K", $guid);
}

sub zfs_get_lun_number {
    my ($class, $scfg, $guid) = @_;

    die "could not find lun_number for guid $guid" if !$guid;

    if ($class->zfs_request($scfg, undef, 'list_view', $guid) =~ /^(\d+)$/) {
        return $1;
    }

    die "lun_number for guid $guid is not a number";
}

# Configuration

sub type {
    return 'zfs';
}

sub plugindata {
    return {
        content => [{ images => 1 }, { images => 1 }],
        'sensitive-properties' => {},
    };
}

sub properties {
    return {
        iscsiprovider => {
            description => "iscsi provider",
            type => 'string',
        },
        # this will disable write caching on comstar and istgt.
        # it is not implemented for iet. iet blockio always operates with
        # writethrough caching when not in readonly mode
        nowritecache => {
            description => "disable write caching on the target",
            type => 'boolean',
        },
        comstar_tg => {
            description => "target group for comstar views",
            type => 'string',
        },
        comstar_hg => {
            description => "host group for comstar views",
            type => 'string',
        },
        lio_tpg => {
            description => "target portal group for Linux LIO targets",
            type => 'string',
        },
        'zfs-base-path' => {
            description => "Base path where to look for the created ZFS block devices. Set"
                . " automatically during creation if not specified. Usually '/dev/zvol'.",
            type => 'string',
            format => 'pve-storage-path',
        },
    };
}

sub options {
    return {
        nodes => { optional => 1 },
        disable => { optional => 1 },
        portal => { fixed => 1 },
        target => { fixed => 1 },
        pool => { fixed => 1 },
        blocksize => { fixed => 1 },
        iscsiprovider => { fixed => 1 },
        nowritecache => { optional => 1 },
        sparse => { optional => 1 },
        comstar_hg => { optional => 1 },
        comstar_tg => { optional => 1 },
        lio_tpg => { optional => 1 },
        content => { optional => 1 },
        bwlimit => { optional => 1 },
        'zfs-base-path' => { optional => 1 },
    };
}

# Storage implementation

sub on_add_hook {
    my ($class, $storeid, $scfg, %param) = @_;

    if (!$scfg->{'zfs-base-path'}) {
        my $base_path;
        if ($scfg->{iscsiprovider} eq 'comstar') {
            $base_path = PVE::Storage::LunCmd::Comstar::get_base($scfg);
        } elsif ($scfg->{iscsiprovider} eq 'istgt') {
            $base_path = PVE::Storage::LunCmd::Istgt::get_base($scfg);
        } elsif ($scfg->{iscsiprovider} eq 'iet' || $scfg->{iscsiprovider} eq 'LIO') {
            # Provider implementations hard-code '/dev/', which does not work for distributions like
	    # Debian 12. Keep that implementation as-is for backwards compatibility, but use custom
	    # logic here.
	    my $target = 'root@' . $scfg->{portal};
	    my $cmd = [@ssh_cmd, '-i', "$id_rsa_path/$scfg->{portal}_id_rsa", $target];
	    push $cmd->@*, 'ls', '/dev/zvol';

	    my $rc = eval { run_command($cmd, timeout => 10, noerr => 1, quiet => 1) };
	    my $err = $@;
	    if (defined($rc) && $rc == 0) {
		$base_path = '/dev/zvol';
	    } elsif (defined($rc) && $rc == ENOENT) {
		$base_path = '/dev';
	    } else {
		my $message = $err ? $err : "remote command failed";
		chomp($message);
		$message .= " ($rc)" if defined($rc);
		$message .= " - check 'zfs-base-path' setting manually!";
		log_warn($message);
		$base_path = '/dev/zvol';
	    }
        } else {
            $zfs_unknown_scsi_provider->($scfg->{iscsiprovider});
        }

        $scfg->{'zfs-base-path'} = $base_path;
    }

    return;
}

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    die "direct access to snapshots not implemented"
        if defined($snapname);

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    my $target = $scfg->{target};
    my $portal = $scfg->{portal};

    my $guid = $class->zfs_get_lu_name($scfg, $name);
    my $lun = $class->zfs_get_lun_number($scfg, $guid);

    my $path = "iscsi://$portal/$target/$lun";

    return ($path, $vmid, $vtype);
}

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;

    my $snap = '__base__';

    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase) = $class->parse_volname($volname);

    die "create_base not possible with base image\n" if $isBase;

    my $newname = $name;
    $newname =~ s/^vm-/base-/;

    my $newvolname = $basename ? "$basename/$newname" : "$newname";

    $class->zfs_delete_lu($scfg, $name);
    $class->zfs_request($scfg, undef, 'rename', "$scfg->{pool}/$name", "$scfg->{pool}/$newname");

    my $guid = $class->zfs_create_lu($scfg, $newname);
    $class->zfs_add_lun_mapping_entry($scfg, $newname, $guid);

    my $running = undef; #fixme : is create_base always offline ?

    $class->volume_snapshot($scfg, $storeid, $newname, $snap, $running);

    return $newvolname;
}

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap) = @_;

    my $name = $class->SUPER::clone_image($scfg, $storeid, $volname, $vmid, $snap);

    # get ZFS dataset name from PVE volname
    my (undef, $clonedname) = $class->parse_volname($name);

    my $guid = $class->zfs_create_lu($scfg, $clonedname);
    $class->zfs_add_lun_mapping_entry($scfg, $clonedname, $guid);

    return $name;
}

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    die "unsupported format '$fmt'" if $fmt ne 'raw';

    die "illegal name '$name' - should be 'vm-$vmid-*'\n"
        if $name && $name !~ m/^vm-$vmid-/;

    my $volname = $name;

    $volname = $class->find_free_diskname($storeid, $scfg, $vmid, $fmt) if !$volname;

    $class->zfs_create_zvol($scfg, $volname, $size);

    my $guid = $class->zfs_create_lu($scfg, $volname);
    $class->zfs_add_lun_mapping_entry($scfg, $volname, $guid);

    return $volname;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    $class->zfs_delete_lu($scfg, $name);

    eval { $class->zfs_delete_zvol($scfg, $name); };
    if (my $err = $@) {
        my $guid = $class->zfs_create_lu($scfg, $name);
        $class->zfs_add_lun_mapping_entry($scfg, $name, $guid);
        die $err;
    }

    return undef;
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;

    $volname = ($class->parse_volname($volname))[1];

    my $new_size = $class->SUPER::volume_resize($scfg, $storeid, $volname, $size, $running);

    $class->zfs_resize_lu($scfg, $volname, $new_size);

    return $new_size;
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;

    $volname = ($class->parse_volname($volname))[1];

    $class->zfs_request($scfg, undef, 'destroy', "$scfg->{pool}/$volname\@$snap");
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    $volname = ($class->parse_volname($volname))[1];

    $class->zfs_delete_lu($scfg, $volname);

    $class->zfs_request($scfg, undef, 'rollback', "$scfg->{pool}/$volname\@$snap");

    $class->zfs_import_lu($scfg, $volname);

    $class->zfs_add_lun_mapping_entry($scfg, $volname);
}

sub storage_can_replicate {
    my ($class, $scfg, $storeid, $format) = @_;

    return 0;
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;

    my $features = {
        snapshot => { current => 1, snap => 1 },
        clone => { base => 1 },
        template => { current => 1 },
        copy => { base => 1, current => 1 },
    };

    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase) = $class->parse_volname($volname);

    my $key = undef;

    if ($snapname) {
        $key = 'snap';
    } else {
        $key = $isBase ? 'base' : 'current';
    }

    return 1 if $features->{$feature}->{$key};

    return undef;
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    return 1;
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    die "unable to activate snapshot from remote zfs storage" if $snapname;

    return 1;
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    die "unable to deactivate snapshot from remote zfs storage" if $snapname;

    return 1;
}

1;
