package PVE::Storage::Custom::TrueNAS;

# TrueNAS Custom Storage Plugin for Proxmox VE
#
# Manages ZFS volumes over iSCSI via the TrueNAS REST API.
# Discovered automatically by PVE — no patches to system files required.
#
# Supports: TrueNAS CORE 13.x, TrueNAS SCALE <= 24.10 (REST API v2.0)
# Auth:     Bearer token (API key) only — basic auth removed in v3.0
# iSCSI:    iscsiadm on PVE host for session login/logout (unavoidable)

use strict;
use warnings;

use JSON            qw(encode_json decode_json);
use LWP::UserAgent  ();
use HTTP::Request   ();
use URI::Escape     qw(uri_escape);
use Sys::Syslog     qw(syslog);

use PVE::Tools          qw(run_command);
use PVE::Storage::Plugin;

use base qw(PVE::Storage::Plugin);

our $VERSION = '3.0.0';

# Per-host runtime state cache: { $host => { ua, target => { id, iqn } } }
my $state = {};

# ── Plugin identity ───────────────────────────────────────────────────────────

sub api  { return 11; }
sub type { return 'truenas'; }

sub plugindata {
    return {
        content => [ { images => 1, rootdir => 1 }, { images => 1 } ],
        format  => [ { raw    => 1 },               'raw'           ],
        # sensitive-properties intentionally omitted: PVE strips those keys from
        # $param before check_config and passes them only to on_add_hook/on_update_hook,
        # which means activate_storage never sees them.  The API key lives in
        # storage.cfg (root-readable only, same as the v2.x truenas_secret).
        # Proper private-key storage via on_add_hook is tracked in issue #247.
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
            description => "iSCSI target IQN. Leave blank to auto-discover from TrueNAS API.",
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

# ── Private: TrueNAS domain helpers ──────────────────────────────────────────

# Returns the zvol parent dataset path: "pool" or "pool/dataset"
sub _zvol_prefix {
    my ($scfg) = @_;
    my $prefix = $scfg->{truenas_pool};
    $prefix .= "/$scfg->{truenas_dataset}" if $scfg->{truenas_dataset};
    return $prefix;
}

# Returns the iSCSI portal IP/hostname to use for iscsiadm
sub _portal {
    my ($scfg) = @_;
    return $scfg->{truenas_portal_ip} // $scfg->{truenas_host};
}

# Resolves and caches { id, iqn } for this storage's iSCSI target.
# Uses truenas_target if configured; otherwise auto-discovers from the API.
sub _resolve_target {
    my ($scfg) = @_;
    my $host = $scfg->{truenas_host};

    return $state->{$host}{target} if $state->{$host}{target};

    my $targets = _api($scfg, 'GET', '/iscsi/target') // [];

    # Explicit IQN or target name configured
    if (my $configured = $scfg->{truenas_target}) {
        for my $t (@$targets) {
            # Accept full IQN (basename:name) or just the target name portion
            if ($configured eq $t->{name} || $configured =~ /:\Q$t->{name}\E$/) {
                $state->{$host}{target} = { id => $t->{id}, iqn => $configured };
                _log('info', "Using configured iSCSI target: $configured (id=$t->{id})");
                return $state->{$host}{target};
            }
        }
        die "Configured iSCSI target '$configured' not found on $host. "
          . "Verify the target name in TrueNAS or update truenas_target.\n";
    }

    # Auto-discover: find targets reachable via our portal IP
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

    unless (%our_portal_ids) {
        die "No iSCSI portals found listening on $portal_ip on $host. "
          . "Configure a portal in TrueNAS iSCSI settings or set truenas_portal_ip.\n";
    }

    # Filter targets by portal using target.groups[].portal.
    # This works on both TrueNAS CORE (no /iscsi/targetgroup endpoint) and SCALE.
    my @matched = grep {
        my $t = $_;
        grep { $our_portal_ids{ $_->{portal} } } @{ $t->{groups} // [] };
    } @$targets;

    if (@matched == 0) {
        die "No iSCSI targets found for portal $portal_ip on $host. "
          . "Create a target in TrueNAS or set truenas_target.\n";
    }
    if (@matched > 1) {
        my $names = join(', ', map { $_->{name} } @matched);
        die "Multiple iSCSI targets found for portal $portal_ip on $host: $names. "
          . "Set truenas_target to specify which one.\n";
    }

    my $global   = _api($scfg, 'GET', '/iscsi/global') // {};
    my $basename = $global->{basename} // 'iqn.2005-10.org.freenas.ctl';
    my $t        = $matched[0];
    my $iqn      = "$basename:$t->{name}";

    $state->{$host}{target} = { id => $t->{id}, iqn => $iqn };
    _log('info', "Auto-discovered iSCSI target: $iqn (id=$t->{id})");
    return $state->{$host}{target};
}

# Returns the next unused LUN ID on the given target
sub _next_lun_id {
    my ($scfg, $target_id) = @_;
    my $tes  = _api($scfg, 'GET', "/iscsi/targetextent?target=$target_id") // [];
    my %used = map { $_->{lunid} => 1 } @$tes;
    my $lun  = 0;
    $lun++ while $used{$lun};
    return $lun;
}

# Returns { extent_id, targetextent_id, lun_id } for a volname, or undef.
sub _find_extent {
    my ($scfg, $volname) = @_;

    my $extents = _api($scfg, 'GET', '/iscsi/extent') // [];
    my ($ext)   = grep { $_->{name} eq $volname } @$extents;
    return undef unless $ext;

    my $tes  = _api($scfg, 'GET', "/iscsi/targetextent?extent=$ext->{id}") // [];
    my ($te) = @$tes;

    return {
        extent_id       => $ext->{id},
        targetextent_id => defined $te ? $te->{id}    : undef,
        lun_id          => defined $te ? $te->{lunid} : 0,
    };
}

# Signal TrueNAS to reload the iSCSI service so new extents are visible
sub _reload_iscsi {
    my ($scfg) = @_;
    eval { _api($scfg, 'POST', '/service/reload', { service => 'iscsitarget' }) };
    _log('warning', "iSCSI reload failed (non-fatal): $@") if $@;
}

# ── Private: iSCSI / iscsiadm helpers ────────────────────────────────────────

# Returns true if an iscsiadm session for the given IQN is already active
sub _iscsi_session_exists {
    my ($iqn) = @_;
    my $out = '';
    eval {
        run_command(['iscsiadm', '-m', 'session'],
                    outfunc => sub { $out .= shift . "\n" },
                    noerr   => 1);
    };
    return $out =~ /\Q$iqn\E/;
}

# Returns the /dev/disk/by-path path for an iSCSI LUN
sub _dev_path {
    my ($portal, $iqn, $lun_id) = @_;
    return "/dev/disk/by-path/ip-${portal}:3260-iscsi-${iqn}-lun-${lun_id}";
}

# Waits up to $timeout seconds for a block device node to appear.
# Rescans the iSCSI session periodically so the kernel discovers new LUNs
# that were added after the session was established.
sub _wait_for_device {
    my ($dev_path, $timeout) = @_;
    $timeout //= 30;
    for my $i (1 .. $timeout) {
        return 1 if -b $dev_path;
        # Rescan at t=1, 6, 11, 16 … to pick up newly exported LUNs
        eval { run_command(['iscsiadm', '-m', 'session', '--rescan'], noerr => 1) }
            if $i % 5 == 1;
        sleep 1;
    }
    die "Timed out after ${timeout}s waiting for device $dev_path\n";
}

# Ensure the iscsiadm session is established for this storage.
# Runs sendtargets discovery then logs in. Safe to call when already connected.
sub _iscsi_ensure_session {
    my ($scfg) = @_;

    my $target = _resolve_target($scfg);
    my $portal = _portal($scfg);
    my $iqn    = $target->{iqn};

    return if _iscsi_session_exists($iqn);

    _log('info', "Logging in to iSCSI target $iqn via $portal:3260");

    # Discovery populates the node record so --login works on first connect
    eval {
        run_command(
            ['iscsiadm', '-m', 'discovery', '-t', 'sendtargets', '-p', "$portal:3260"],
            noerr => 1,
        );
    };

    run_command(
        ['iscsiadm', '-m', 'node', '-T', $iqn, '-p', "$portal:3260", '--login'],
        errmsg => "iscsiadm login failed for target $iqn on $portal",
    );
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

    # Query the root dataset for space stats — works on both CORE and SCALE.
    # TrueNAS CORE 13.0 /pool does not expose top-level size/free/allocated;
    # those fields are nested inside topology.  /pool/dataset has available.parsed
    # and used.parsed at the root dataset level on all versions.
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

    _log('info', "alloc_image: creating zvol $zvol ($size_b bytes)");

    # 1. Create the zvol
    _api($scfg, 'POST', '/pool/dataset', {
        name   => $zvol,
        type   => 'VOLUME',
        volsize => $size_b,
        sparse => JSON::true,
    });

    # 2. Create the iSCSI extent pointing at the new zvol
    my $extent = _api($scfg, 'POST', '/iscsi/extent', {
        name => $name,
        type => 'DISK',
        disk => "zvol/$zvol",
        ro   => JSON::false,
    });

    # 3. Associate the extent with the target at the next available LUN ID
    my $target = _resolve_target($scfg);
    my $lun_id = _next_lun_id($scfg, $target->{id});

    _api($scfg, 'POST', '/iscsi/targetextent', {
        target => $target->{id},
        extent => $extent->{id},
        lunid  => $lun_id,
    });

    _reload_iscsi($scfg);

    _log('info', "alloc_image: $name ready at lun $lun_id");
    return $name;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;

    _log('info', "free_image: removing $volname");

    my $ext = _find_extent($scfg, $volname);

    if ($ext) {
        if (defined $ext->{targetextent_id}) {
            # TrueNAS CORE 13 keeps iSCSI sessions in recovery state after TCP
            # disconnect — a reload is not sufficient to clear them.  A service
            # restart immediately purges all server-side session state, which is
            # the only reliable way to allow targetextent deletion.
            my $target = _resolve_target($scfg);
            my $portal = _portal($scfg);
            my $iqn    = $target->{iqn};

            # Logout from the initiator side
            my $sessions = '';
            eval { run_command(['iscsiadm', '-m', 'session'],
                               outfunc => sub { $sessions .= shift . "\n" },
                               noerr   => 1) };
            if ($sessions =~ /\[(\d+)\][^\n]*\Q$iqn\E/) {
                my $sid = $1;
                _log('info', "free_image: logging out iSCSI session $sid");
                eval { run_command(['iscsiadm', '-m', 'session', '-r', $sid, '--logout'],
                                   noerr => 1) };
            }

            # Restart TrueNAS iSCSI service to immediately clear server-side sessions
            _log('info', "free_image: restarting TrueNAS iSCSI service to clear session state");
            _api($scfg, 'POST', '/service/restart', { service => 'iscsitarget' });

            _api($scfg, 'DELETE', "/iscsi/targetextent/id/$ext->{targetextent_id}");
            _api($scfg, 'DELETE', "/iscsi/extent/id/$ext->{extent_id}");

            # Restore the session so remaining LUNs stay accessible
            _log('info', "free_image: restoring iSCSI session");
            eval { run_command(['iscsiadm', '-m', 'discovery', '-t', 'sendtargets',
                                '-p', "$portal:3260"], noerr => 1) };
            eval { run_command(['iscsiadm', '-m', 'node', '-T', $iqn,
                                '-p', "$portal:3260", '--login'], noerr => 1) };
            eval { run_command(['iscsiadm', '-m', 'session', '--rescan'], noerr => 1) };
        } else {
            _api($scfg, 'DELETE', "/iscsi/extent/id/$ext->{extent_id}");
            _reload_iscsi($scfg);
        }
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

        # Keep only zvols directly under our prefix
        next unless $name =~ s{^\Q$prefix\E/}{};
        next if $name =~ m{/};    # skip nested datasets

        # Must match PVE volume naming: vm-<vmid>-<rest> or base-<vmid>-<rest>
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

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    my $ext = _find_extent($scfg, $volname);
    die "Volume '$volname' has no iSCSI extent on $scfg->{truenas_host}. "
      . "Was it created via this plugin?\n" unless $ext;

    my $target = _resolve_target($scfg);
    my $dev    = _dev_path(_portal($scfg), $target->{iqn}, $ext->{lun_id});

    my ($vtype, undef, $ds_vmid) = $class->parse_volname($volname);
    return ($dev, $ds_vmid, $vtype);
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    # Warm up target cache and verify API reachability
    _resolve_target($scfg);

    _iscsi_ensure_session($scfg);

    _log('info', "activate_storage: $storeid online");
    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $host   = $scfg->{truenas_host};
    my $target = $state->{$host}{target};

    if ($target) {
        my $portal = _portal($scfg);
        eval {
            run_command(
                ['iscsiadm', '-m', 'node', '-T', $target->{iqn},
                 '-p', "$portal:3260", '--logout'],
                noerr => 1,
            );
        };
    }

    delete $state->{$host};
    _log('info', "deactivate_storage: $storeid offline");
    return 1;
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    # Reconnect if the session dropped (e.g. after a node reboot)
    _iscsi_ensure_session($scfg);

    my $ext = _find_extent($scfg, $volname);
    die "Volume '$volname' has no iSCSI extent — was it created via this plugin?\n"
        unless $ext;

    my $target = _resolve_target($scfg);
    my $dev    = _dev_path(_portal($scfg), $target->{iqn}, $ext->{lun_id});

    _wait_for_device($dev);

    _log('info', "activate_volume: $volname ready at $dev (lun $ext->{lun_id})");
    return 1;
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    # Session lifecycle managed at storage level — nothing to do per-volume
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
