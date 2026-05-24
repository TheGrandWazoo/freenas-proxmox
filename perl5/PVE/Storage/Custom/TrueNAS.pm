package PVE::Storage::Custom::TrueNAS;

# TrueNAS Custom Storage Plugin for Proxmox VE
#
# Manages ZFS volumes over iSCSI via the TrueNAS REST API.
# Discovered automatically by PVE — no patches to system files required.
#
# Supports: TrueNAS CORE 13.x, TrueNAS SCALE <= 24.10 (REST API v2.0)
# Auth:     Bearer token (API key) only — basic auth removed in v3.0
# iSCSI:    QEMU libiscsi (iscsi:// paths) — no iscsiadm session management
#
# Per-VM target architecture:
#   Each VM gets its own iSCSI target (proxmox-vm-<vmid>).
#   path() returns iscsi://portal/iqn:proxmox-vm-<vmid>/lun — QEMU connects via
#   libiscsi.  When the VM stops, QEMU's connection closes.  TrueNAS sees no
#   active session on that target, so extent DELETE (force=true) works without
#   stopping the TrueNAS iSCSI service.

use strict;
use warnings;

use JSON            qw(encode_json decode_json);
use LWP::UserAgent  ();
use HTTP::Request   ();
use URI::Escape     qw(uri_escape);
use Sys::Syslog     qw(syslog);

use PVE::Storage::Plugin;

use base qw(PVE::Storage::Plugin);

our $VERSION = '3.0.0';

# Per-host runtime state cache
my $state = {};

# ── Plugin identity ───────────────────────────────────────────────────────────

sub api  { return 11; }
sub type { return 'truenas'; }

sub plugindata {
    return {
        content => [ { images => 1 }, { images => 1 } ],
        format  => [ { raw    => 1 },               'raw'           ],
    };
}

sub properties {
    return {
        truenas_host => {
            description => "TrueNAS hostname or IP address",
            type        => 'string',
        },
        truenas_api_key => {
            description => "TrueNAS API key (Bearer token — generate in TrueNAS UI under Credentials > API Keys)",
            type        => 'string',
        },
        truenas_ssl => {
            description => "Use HTTPS for TrueNAS API (recommended)",
            type        => 'boolean',
            default     => 1,
        },
        truenas_ssl_verify => {
            description => "Verify TrueNAS SSL certificate (disable for self-signed certs)",
            type        => 'boolean',
            default     => 0,
        },
        truenas_pool => {
            description => "ZFS pool or dataset path where PVE volumes are created "
                         . "(e.g. 'tank' or 'tank/proxmox/vdisks'). "
                         . "Matches the 'pool' field from the v2.x plugin.",
            type        => 'string',
        },
        truenas_dataset => {
            description => "Optional additional sub-dataset appended to Pool path. "
                         . "Leave blank — put the full path in Pool instead.",
            type        => 'string',
        },
        truenas_portal_ip => {
            description => "iSCSI portal IP address. Defaults to truenas_host if not set.",
            type        => 'string',
        },
        truenas_target => {
            description => "Base iSCSI target name (used to look up portal and initiator "
                         . "group settings for auto-created per-VM targets). "
                         . "Leave blank to auto-discover from the portal IP.",
            type        => 'string',
        },
    };
}

sub options {
    return {
        nodes              => { optional => 1 },
        disable            => { optional => 1 },
        content            => { optional => 1 },
        bwlimit            => { optional => 1 },
        shared             => { optional => 1 },
        truenas_host       => { fixed    => 1 },
        truenas_api_key    => {},
        truenas_ssl        => { optional => 1 },
        truenas_ssl_verify => { optional => 1 },
        truenas_pool       => { fixed    => 1 },
        truenas_dataset    => { optional => 1 },
        truenas_portal_ip  => { optional => 1 },
        truenas_target     => { optional => 1 },
    };
}

# ── Private: logging ──────────────────────────────────────────────────────────

sub _log {
    my ($level, $msg) = @_;
    syslog($level, "TrueNASPlugin: $msg");
}

# ── Private: HTTP/API helpers ─────────────────────────────────────────────────

sub _ua {
    my ($scfg) = @_;
    my $host = $scfg->{truenas_host};
    unless ($state->{$host}{ua}) {
        my $ua = LWP::UserAgent->new(timeout => 30);
        if ($scfg->{truenas_ssl} // 1) {
            unless ($scfg->{truenas_ssl_verify} // 0) {
                $ua->ssl_opts(verify_hostname => 0, SSL_verify_mode => 0);
            }
        }
        $state->{$host}{ua} = $ua;
    }
    return $state->{$host}{ua};
}

# Make a TrueNAS REST API v2.0 call.
# Dies with a descriptive message on HTTP error.
# Returns decoded JSON hashref/arrayref, or undef for empty 204 responses.
sub _api {
    my ($scfg, $method, $path, $data) = @_;

    die "TrueNAS API key is not configured for storage '$scfg->{truenas_host}'\n"
        unless $scfg->{truenas_api_key};

    my $scheme = ($scfg->{truenas_ssl} // 1) ? 'https' : 'http';
    my $url    = "$scheme://$scfg->{truenas_host}/api/v2.0$path";

    my $req = HTTP::Request->new(uc($method) => $url);
    $req->header('Content-Type'  => 'application/json');
    $req->header('Accept'        => 'application/json');
    $req->header('Authorization' => "Bearer $scfg->{truenas_api_key}");
    $req->content(encode_json($data)) if defined $data;

    my $res = _ua($scfg)->request($req);

    unless ($res->is_success) {
        my $detail = '';
        eval {
            my $body = decode_json($res->content);
            $detail = " — $body->{message}" if ref $body eq 'HASH' && $body->{message};
        };
        my $msg = "TrueNAS API $method $path: " . $res->status_line . $detail;
        _log('err', $msg);
        die "$msg\n";
    }

    my $content = $res->content // '';
    return undef unless length($content);
    return decode_json($content);
}

# Returns (and caches) the iSCSI global config { basename, ... }
sub _api_global {
    my ($scfg) = @_;
    my $host = $scfg->{truenas_host};
    $state->{$host}{global} //= _api($scfg, 'GET', '/iscsi/global') // {};
    return $state->{$host}{global};
}

# ── Private: TrueNAS domain helpers ──────────────────────────────────────────

# Returns the zvol parent dataset path: "pool" or "pool/dataset"
sub _zvol_prefix {
    my ($scfg) = @_;
    my $prefix = $scfg->{truenas_pool};
    $prefix .= "/$scfg->{truenas_dataset}" if $scfg->{truenas_dataset};
    return $prefix;
}

# Returns the iSCSI portal IP/hostname to use
sub _portal {
    my ($scfg) = @_;
    return $scfg->{truenas_portal_ip} // $scfg->{truenas_host};
}

# Returns the iSCSI global basename (e.g. "iqn.2005-10.org.freenas.ctl")
sub _basename {
    my ($scfg) = @_;
    return _api_global($scfg)->{basename} // 'iqn.2005-10.org.freenas.ctl';
}

# Finds the [ { portal, initiator, authmethod, auth } ] group list to use when
# creating new per-VM targets.  Copies the first group found on an existing
# target that uses our portal IP, so security settings (initiator group, auth)
# are inherited automatically.
sub _portal_groups_for_new_target {
    my ($scfg) = @_;

    my $portal_ip = _portal($scfg);
    my $portals   = _api($scfg, 'GET', '/iscsi/portal') // [];

    my %our_portal_ids;
    for my $p (@$portals) {
        for my $listen (@{$p->{listen} // []}) {
            my $ip = $listen->{ip} // '';
            if ($ip eq $portal_ip || $ip eq '0.0.0.0' || $ip eq '::') {
                $our_portal_ids{$p->{id}} = 1;
                last;
            }
        }
    }

    die "No iSCSI portals found listening on $portal_ip — "
      . "cannot create per-VM targets. Check truenas_portal_ip.\n"
        unless %our_portal_ids;

    my $targets = _api($scfg, 'GET', '/iscsi/target') // [];

    # Prefer copying groups from the configured base target
    if (my $base = $scfg->{truenas_target}) {
        my ($bt) = grep { $_->{name} eq $base || "$_->{name}" =~ /:\Q$base\E$/ } @$targets;
        if ($bt) {
            my @gs = grep { $our_portal_ids{$_->{portal}} } @{$bt->{groups} // []};
            return _clean_groups(\@gs) if @gs;
        }
    }

    # Fall back to any existing target that uses our portal
    for my $t (@$targets) {
        my @gs = grep { $our_portal_ids{$_->{portal}} } @{$t->{groups} // []};
        return _clean_groups(\@gs) if @gs;
    }

    # No existing targets — use first matching portal, no initiator restriction
    my ($pid) = keys %our_portal_ids;
    return [ { portal => $pid, initiator => undef, authmethod => 'NONE', auth => undef } ];
}

sub _clean_groups {
    my ($gs) = @_;
    return [ map { {
        portal     => $_->{portal},
        initiator  => $_->{initiator},
        authmethod => $_->{authmethod} // 'NONE',
        auth       => $_->{auth},
    } } @$gs ];
}

# Finds or creates the per-VM iSCSI target for $vmid.
# Returns { id, iqn }.
sub _resolve_vm_target {
    my ($scfg, $vmid) = @_;
    my $host = $scfg->{truenas_host};

    return $state->{$host}{vm_targets}{$vmid}
        if $state->{$host}{vm_targets}{$vmid};

    my $target_name = "proxmox-vm-$vmid";
    my $targets     = _api($scfg, 'GET', '/iscsi/target') // [];
    my ($existing)  = grep { $_->{name} eq $target_name } @$targets;

    my ($t_id, $iqn);
    if ($existing) {
        $t_id = $existing->{id};
        $iqn  = _basename($scfg) . ":$target_name";
        _log('info', "Using existing per-VM target: $iqn (id=$t_id)");
    } else {
        my $groups = _portal_groups_for_new_target($scfg);
        my $new    = _api($scfg, 'POST', '/iscsi/target', {
            name   => $target_name,
            alias  => "Proxmox VM $vmid",
            mode   => 'ISCSI',
            groups => $groups,
        });
        $t_id = $new->{id};
        $iqn  = _basename($scfg) . ":$target_name";
        _log('info', "Created per-VM target: $iqn (id=$t_id)");
    }

    $state->{$host}{vm_targets}{$vmid} = { id => $t_id, iqn => $iqn };
    return $state->{$host}{vm_targets}{$vmid};
}

# Deletes the per-VM target if it has no remaining targetextent associations.
sub _maybe_cleanup_vm_target {
    my ($scfg, $vmid, $target_id) = @_;
    return unless defined $target_id;

    my $tes = _api($scfg, 'GET', "/iscsi/targetextent?target=$target_id") // [];
    return if @$tes;    # still has extents — don't remove

    eval { _api($scfg, 'DELETE', "/iscsi/target/id/$target_id") };
    if ($@) {
        _log('warning', "could not remove empty per-VM target id=$target_id (vm=$vmid): $@");
    } else {
        _log('info', "removed empty per-VM target id=$target_id (vm=$vmid)");
        my $host = $scfg->{truenas_host};
        delete $state->{$host}{vm_targets}{$vmid};
    }
}

# Returns true if the QEMU process for $vmid is alive.
# Returns the next unused LUN ID on the given target
sub _next_lun_id {
    my ($scfg, $target_id) = @_;
    my $tes  = _api($scfg, 'GET', "/iscsi/targetextent?target=$target_id") // [];
    my %used = map { $_->{lunid} => 1 } @$tes;
    my $lun  = 0;
    $lun++ while $used{$lun};
    return $lun;
}

# Returns { extent_id, targetextent_id, lun_id, target_id } for a volname,
# or undef if no extent exists.
sub _find_extent {
    my ($scfg, $volname) = @_;

    my $extents = _api($scfg, 'GET', '/iscsi/extent') // [];
    my ($ext)   = grep { $_->{name} eq $volname } @$extents;
    return undef unless $ext;

    my $tes  = _api($scfg, 'GET', "/iscsi/targetextent?extent=$ext->{id}") // [];
    my ($te) = @$tes;

    return {
        extent_id       => $ext->{id},
        targetextent_id => defined $te ? $te->{id}     : undef,
        lun_id          => defined $te ? $te->{lunid}  : 0,
        target_id       => defined $te ? $te->{target} : undef,
    };
}

# Signal TrueNAS to reload the iSCSI service so new extents are visible
sub _reload_iscsi {
    my ($scfg) = @_;
    eval { _api($scfg, 'POST', '/service/reload', { service => 'iscsitarget' }) };
    _log('warning', "iSCSI reload failed (non-fatal): $@") if $@;
}

# ── PVE::Storage::Plugin interface ───────────────────────────────────────────

sub parse_volname {
    my ($class, $volname) = @_;

    if ($volname =~ /^(vm|base)-(\d+)-disk-\d+$/) {
        my ($prefix, $vmid) = ($1, $2);
        my $isBase = $prefix eq 'base' ? 1 : 0;
        return ('images', $volname, $vmid, undef, undef, $isBase, 'raw');
    }

    die "unable to parse TrueNAS volume name '$volname'\n";
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $pool_name = (split m{/}, $scfg->{truenas_pool})[0];
    my $datasets  = _api($scfg, 'GET', "/pool/dataset?id=$pool_name") // [];
    my ($ds)      = grep { $_->{name} eq $pool_name } @$datasets;
    die "Pool dataset '$pool_name' not found on $scfg->{truenas_host}\n" unless $ds;

    my $free  = $ds->{available}{parsed} // 0;
    my $used  = $ds->{used}{parsed}      // 0;
    my $total = $free + $used;

    return ($total, $free, $used, 1);
}

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size_kb) = @_;

    die "Unsupported format '$fmt' — only raw is supported\n" if $fmt && $fmt ne 'raw';

    $name //= $class->find_free_diskname($storeid, $scfg, $vmid, 'raw');

    my $prefix = _zvol_prefix($scfg);
    my $zvol   = "$prefix/$name";
    my $size_b = $size_kb * 1024;

    _log('info', "alloc_image: creating zvol $zvol ($size_b bytes) for VM $vmid");

    # 1. Create the zvol
    _api($scfg, 'POST', '/pool/dataset', {
        name    => $zvol,
        type    => 'VOLUME',
        volsize => $size_b,
        sparse  => JSON::true,
    });

    # 2. Create the iSCSI extent
    my $extent = _api($scfg, 'POST', '/iscsi/extent', {
        name => $name,
        type => 'DISK',
        disk => "zvol/$zvol",
        ro   => JSON::false,
    });

    # 3. Associate extent with the per-VM target
    my $target = _resolve_vm_target($scfg, $vmid);
    my $lun_id = _next_lun_id($scfg, $target->{id});

    _api($scfg, 'POST', '/iscsi/targetextent', {
        target => $target->{id},
        extent => $extent->{id},
        lunid  => $lun_id,
    });

    _reload_iscsi($scfg);

    _log('info', "alloc_image: $name ready at lun $lun_id on $target->{iqn}");
    return $name;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;

    _log('info', "free_image: removing $volname");

    my ($vmid) = $volname =~ /^(?:vm|base)-(\d+)-/;

    my $ext = _find_extent($scfg, $volname);

    if ($ext) {
        # force=true tells TrueNAS to disconnect any remaining iSCSI session
        # before deleting.  For detached disks on a running VM, QEMU has
        # already closed the libiscsi connection, so this is a no-op safety net.
        eval {
            _api($scfg, 'DELETE', "/iscsi/extent/id/$ext->{extent_id}",
                 { force => JSON::true });
        };
        die "free_image: could not delete iSCSI extent for '$volname': $@\n" if $@;

        # Remove the per-VM target if this was its last disk
        _maybe_cleanup_vm_target($scfg, $vmid, $ext->{target_id})
            if $vmid && defined $ext->{target_id};
    } else {
        _log('warning', "free_image: no iSCSI extent found for $volname — skipping extent removal");
    }

    # Delete the zvol; recursive handles any leftover snapshots
    my $zvol    = _zvol_prefix($scfg) . "/$volname";
    my $zvol_id = uri_escape($zvol, "^A-Za-z0-9\\-_.~");
    _api($scfg, 'DELETE', "/pool/dataset/id/$zvol_id", { recursive => JSON::true });

    _log('info', "free_image: $volname removed");
    return undef;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $fmt, $ids) = @_;

    my $prefix   = _zvol_prefix($scfg);
    my $datasets = _api($scfg, 'GET', '/pool/dataset?type=VOLUME') // [];

    my @vols;
    for my $ds (@$datasets) {
        my $name = $ds->{name} // '';

        next unless $name =~ s{^\Q$prefix\E/}{};
        next if $name =~ m{/};

        next unless $name =~ /^(?:vm|base|subvol)-(\d+)-/;
        my $ds_vmid = $1 + 0;

        next if defined $vmid && $ds_vmid != $vmid;

        my $volid = "$storeid:$name";
        next if $ids && !$ids->{$volid};

        my $size = 0;
        eval { $size = $ds->{volsize}{parsed} // 0 };

        push @vols, {
            volid  => $volid,
            name   => $name,
            size   => $size,
            vmid   => $ds_vmid,
            format => 'raw',
        };
    }

    return \@vols;
}

sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;

    my $zvol = _zvol_prefix($scfg) . "/$volname";
    my $enc  = uri_escape($zvol, "^A-Za-z0-9\\-_.~");
    my $ds   = _api($scfg, 'GET', "/pool/dataset/id/$enc") // {};
    return $ds->{volsize}{parsed} // 0;
}

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    my $ext = _find_extent($scfg, $volname);
    die "Volume '$volname' has no iSCSI extent on $scfg->{truenas_host}. "
      . "Was it created via this plugin?\n" unless $ext;

    die "Volume '$volname' is not mapped to any iSCSI target.\n"
        unless defined $ext->{target_id};

    # Look up the target that owns this extent (per-VM or legacy shared)
    my $t        = _api($scfg, 'GET', "/iscsi/target/id/$ext->{target_id}") // {};
    my $iqn      = _basename($scfg) . ":$t->{name}";
    my $portal   = _portal($scfg);
    my $dev_path = "iscsi://$portal/$iqn/$ext->{lun_id}";

    my ($vtype, undef, $ds_vmid) = $class->parse_volname($volname);
    return ($dev_path, $ds_vmid, $vtype);
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    # Verify API reachability and warm up the global config cache
    _api_global($scfg);
    _log('info', "activate_storage: $storeid online");
    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    delete $state->{$scfg->{truenas_host}};
    _log('info', "deactivate_storage: $storeid offline");
    return 1;
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    # QEMU connects via iscsi:// (libiscsi) — no iscsiadm session needed here.
    # Just verify the extent exists so we catch config errors early.
    my $ext = _find_extent($scfg, $volname);
    die "Volume '$volname' has no iSCSI extent — was it created via this plugin?\n"
        unless $ext;
    _log('info', "activate_volume: $volname (lun $ext->{lun_id}) ready");
    return 1;
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    return 1;
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;

    my $features = {
        copy     => { base => 1, current => 1 },
        snapshot => { current => 1 },
    };

    my ($vtype, undef, undef, undef, undef, $isBase) = $class->parse_volname($volname);
    my $key = $snapname ? 'snap' : ($isBase ? 'base' : 'current');

    return 1 if $features->{$feature} && $features->{$feature}{$key};
    return undef;
}

1;
