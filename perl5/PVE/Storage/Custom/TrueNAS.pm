package PVE::Storage::Custom::TrueNAS;

# TrueNAS Custom Storage Plugin for Proxmox VE
#
# Manages ZFS volumes over iSCSI via the TrueNAS API — REST v2.0 (TrueNAS
# CORE, TrueNAS SCALE < 25.04) or WebSocket JSON-RPC 2.0 (TrueNAS SCALE >=
# 25.04, where REST is deprecated and is removed entirely in SCALE 26.x).
# Transport is auto-detected per host (see _transport()) — storage.cfg is
# unchanged either way. Discovered automatically by PVE — no patches to
# system files required. See ADR-012 for the WebSocket transport design.
#
# Supports: TrueNAS CORE 13.x, TrueNAS SCALE 24.10+ (both transports)
# Auth:     Bearer token (API key) only — basic auth removed in v3.0.
#           WebSocket auth uses auth.login_with_api_key specifically, not the
#           newer auth.login_ex — the latter requires a username field this
#           plugin has no way to know for an arbitrary API key (ADR-012).
# iSCSI:    QEMU libiscsi (iscsi:// paths) — no iscsiadm session management
#
# WARNING: the WebSocket transport (_api_ws, _ws_connect, _ws_call) has been
# live-verified for every *read* (query) call this plugin makes (ADR-012,
# four runs across three TrueNAS SCALE versions incl. 25.04.2.6). The
# *write* path (create/delete/update param shapes below) follows TrueNAS's
# documented CRUDService conventions but has NOT yet been independently
# live-tested against a real host — verify against .91/.92 before trusting
# alloc_image/free_image/snapshot operations in production on SCALE 25.04+.
#
# Per-VM target architecture:
#   Each VM gets its own iSCSI target (proxmox-vm-<vmid>).
#   path() returns iscsi://portal/iqn:proxmox-vm-<vmid>/lun — QEMU connects via
#   libiscsi.  Deleting a disk from a running VM (e.g. removing an unused disk)
#   requires force=true on both the targetextent and extent DELETEs — TrueNAS
#   sees the target session as active even when the specific LUN is not in use.

use strict;
use warnings;

use JSON                         qw(encode_json decode_json);
use LWP::UserAgent               ();
use HTTP::Request                ();
use URI::Escape                  qw(uri_escape uri_unescape);
use Sys::Syslog                  qw(syslog);
use AnyEvent                     ();
use AnyEvent::WebSocket::Client  ();

use PVE::Storage::Plugin;

use base qw(PVE::Storage::Plugin);

our $VERSION = '4.0.0';

# Per-host runtime state cache
my $state = {};

# ── Plugin identity ───────────────────────────────────────────────────────────

sub api  { return 15; }
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
            description => "TrueNAS API key (Bearer token). "
                         . "Leave blank to use /etc/pve/priv/truenas-<storeid>.key instead.",
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
        truenas_api_key    => { optional => 1 },
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
    return;
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

# Resolves the API token from /etc/pve/priv/truenas-<storeid>.key (preferred)
# or truenas_api_key in storage.cfg (backwards compat). Caches in $state so
# the keyfile is read at most once per daemon session per host.
sub _resolve_token {
    my ($storeid, $scfg) = @_;
    my $host = $scfg->{truenas_host};
    return if $state->{$host}{api_token};

    my $keyfile = "/etc/pve/priv/truenas-$storeid.key";
    if (-r $keyfile) {
        open(my $fh, '<', $keyfile)
            or die "Cannot read TrueNAS token file '$keyfile': $!\n";
        my $token = do { local $/; <$fh> };
        close $fh;
        $token =~ s/\s+\z//;
        die "TrueNAS token file '$keyfile' is empty\n" unless length $token;
        $state->{$host}{api_token} = $token;
        return;
    }

    die "TrueNAS API token not configured for storage '$storeid'. "
      . "Set truenas_api_key in storage.cfg or create $keyfile\n"
        unless $scfg->{truenas_api_key};

    $state->{$host}{api_token} = $scfg->{truenas_api_key};
    return;
}

# Dispatches to the REST or WebSocket transport based on the detected
# TrueNAS variant/version (see _transport). Every call site in this file
# uses the REST-style (method, path, data) signature regardless of which
# transport actually ends up handling it — _api_ws() translates that
# signature onto the equivalent JSON-RPC 2.0 method. See ADR-012.
sub _api {
    my ($scfg, $method, $path, $data) = @_;
    return _transport($scfg) eq 'ws'
        ? _api_ws($scfg, $method, $path, $data)
        : _api_rest($scfg, $method, $path, $data);
}

# Detects which transport to use for $scfg->{truenas_host}: REST v2.0 for
# TrueNAS CORE and SCALE < 25.04, WebSocket JSON-RPC 2.0 for SCALE >= 25.04
# (where REST is deprecated, and removed entirely in SCALE 26.x). Detection
# itself always uses REST — it remains available for this purpose on every
# currently-supported version — and is cached per host so it only runs once
# per plugin invocation.
#
# Distinguishes CORE from SCALE by version-string magnitude, not the
# /system/product_type endpoint — that field returns the license tier
# (e.g. "COMMUNITY_EDITION"), not the product family, so it can't be used
# for this. SCALE uses calendar versioning (YY.MM[.patch], e.g. 25.04.2.6);
# CORE has only ever used a small integer major (11.x-13.x) and is now
# maintenance-only, so a YY-style major of 24+ is unambiguously SCALE.
sub _transport {
    my ($scfg) = @_;
    my $host = $scfg->{truenas_host};
    return $state->{$host}{transport} if $state->{$host}{transport};

    my $version = eval { _api_rest($scfg, 'GET', '/system/version') } // '';

    my $transport = 'rest';
    if ($version =~ /^TrueNAS-(\d+)\.(\d+)/ && $1 >= 24) {
        my ($maj, $min) = ($1, $2);
        $transport = 'ws' if $maj > 25 || ($maj == 25 && $min >= 4);
    }

    $state->{$host}{transport} = $transport;
    _log('info', "$host: detected version=$version -> $transport transport");
    return $transport;
}

# Make a TrueNAS REST API v2.0 call.
# Dies with a descriptive message on HTTP error.
# Returns decoded JSON hashref/arrayref, or undef for empty 204 responses.
sub _api_rest {
    my ($scfg, $method, $path, $data) = @_;

    my $host  = $scfg->{truenas_host};
    my $token = $state->{$host}{api_token}
        or die "TrueNAS API token not resolved for '$host'\n";

    my $scheme = ($scfg->{truenas_ssl} // 1) ? 'https' : 'http';
    my $url    = "$scheme://$host/api/v2.0$path";

    my $req = HTTP::Request->new(uc($method) => $url);
    $req->header('Content-Type'  => 'application/json');
    $req->header('Accept'        => 'application/json');
    $req->header('Authorization' => "Bearer $token");
    $req->content(encode_json($data)) if defined $data;

    my $res = _ua($scfg)->request($req);

    unless ($res->is_success) {
        my $detail = '';
        eval {
            my $body = decode_json($res->content);
            if (ref $body eq 'HASH' && $body->{message}) {
                $detail = " — $body->{message}";
            } elsif (ref $body eq 'ARRAY' && @$body) {
                # SCALE 25.04+ returns Pydantic validation errors as an array
                my @msgs = map { $_->{message} // $_->{msg} // '' } @$body;
                $detail = " — " . join('; ', grep { length } @msgs);
            } elsif (ref $body eq 'HASH') {
                # SCALE 25.10+ returns field-keyed validation errors: { "field": [{message}...] }
                my @msgs;
                for my $field (sort keys %$body) {
                    my $errs = $body->{$field};
                    next unless ref $errs eq 'ARRAY';
                    push @msgs, map { "$field: " . ($_->{message} // '') } @$errs;
                }
                $detail = " — " . join('; ', grep { length } @msgs) if @msgs;
            }
        };
        my $msg = "TrueNAS API $method $path: " . $res->status_line . $detail;
        _log('err', $msg);
        die "$msg\n";
    }

    my $content = $res->content // '';
    return unless length($content);
    return decode_json($content);
}

# ── Private: WebSocket JSON-RPC 2.0 transport (TrueNAS SCALE 25.04+) ─────────
#
# See ADR-012 for the full design and live-verification history. Summary:
# - AnyEvent::WebSocket::Client, used in blocking style (condvar ->recv) to
#   match this plugin's existing per-invocation synchronous lifecycle — no
#   persistent event loop needed, same as the LWP::UserAgent path above.
# - Auth is auth.login_with_api_key (single positional [api_key] param) —
#   NOT auth.login_ex, which requires a username field this plugin has no
#   way to know for an arbitrary API key.
# - decode_json turns JSON true/false into a blessed JSON::PP::Boolean
#   object, not a plain 1/0 — ref() on it is truthy. Never assume a non-hash
#   JSON-RPC result is a plain scalar without checking ref() eq 'HASH' first.

# Opens (and caches) an authenticated WebSocket connection for $scfg's host.
sub _ws_connect {
    my ($scfg) = @_;
    my $host = $scfg->{truenas_host};
    return $state->{$host}{ws} if $state->{$host}{ws};

    my $token = $state->{$host}{api_token}
        or die "TrueNAS API token not resolved for '$host'\n";

    my $url    = "wss://$host/api/current";
    my $client = AnyEvent::WebSocket::Client->new(
        ssl_no_verify => ($scfg->{truenas_ssl_verify} // 0) ? 0 : 1,
        timeout       => 30,
    );

    my $conn = eval { $client->connect($url)->recv };
    die "TrueNAS WebSocket connect to $host failed: $@" if $@;

    $state->{$host}{ws} = {
        conn    => $conn,
        pending => {},
        next_id => 1,
    };

    $conn->on(each_message => sub {
        my (undef, $message) = @_;
        my $body = eval { decode_json($message->body) };
        return unless $body;
        my $id = $body->{id};
        my $pending = $state->{$host}{ws}{pending};
        return unless defined $id && $pending->{$id};
        (delete $pending->{$id})->send($body);
    });
    $conn->on(finish => sub {
        delete $state->{$host}{ws};
    });

    my $auth = _ws_call($scfg, 'auth.login_with_api_key', [$token]);
    unless (!$auth->{error} && $auth->{result}) {
        my $reason = $auth->{error}{message} // 'authentication rejected';
        delete $state->{$host}{ws};
        die "TrueNAS WebSocket auth failed for $host: $reason\n";
    }

    return $state->{$host}{ws};
}

# Makes one JSON-RPC 2.0 call over an already-connected WebSocket.
# Returns the decoded {result=>...} or {error=>...} response envelope —
# callers (normally just _api_ws) are responsible for checking ->{error}.
sub _ws_call {
    my ($scfg, $method, $params) = @_;
    my $host = $scfg->{truenas_host};
    my $ws   = $state->{$host}{ws}
        or die "TrueNAS WebSocket connection not established for '$host'\n";

    my $id  = $ws->{next_id}++;
    my $req = { jsonrpc => '2.0', id => $id, method => $method, params => $params // [] };

    my $cv = AnyEvent->condvar;
    $ws->{pending}{$id} = $cv;
    $ws->{conn}->send(encode_json($req));

    my $timeout_w = AnyEvent->timer(after => 30, cb => sub {
        return unless $ws->{pending}{$id};
        delete $ws->{pending}{$id};
        $cv->send({ error => { message => "TrueNAS WebSocket call '$method' timed out after 30s" } });
    });
    my $resp = $cv->recv;
    undef $timeout_w;
    return $resp;
}

# Translates a REST-style (method, path, data) call onto its JSON-RPC 2.0
# equivalent and executes it over _ws_connect's transport. Read (query)
# mappings are confirmed live (ADR-012); write mappings are inferred from
# TrueNAS's documented CRUDService conventions — see the file header warning.
sub _api_ws {
    my ($scfg, $method, $path, $data) = @_;
    _ws_connect($scfg);

    $method = uc($method);
    my ($base, $qs) = split /\?/, $path, 2;
    my %q;
    if (defined $qs) {
        for my $pair (split /&/, $qs) {
            my ($k, $v) = split /=/, $pair, 2;
            $q{$k} = $v;
        }
    }

    my ($rpc_method, $params, $single);

    if ($base eq '/iscsi/global') {
        $rpc_method = 'iscsi.global.config';
        $params     = [];

    } elsif ($base eq '/iscsi/portal') {
        $rpc_method = 'iscsi.portal.query';
        $params     = [[], {}];

    } elsif ($base eq '/iscsi/target') {
        if ($method eq 'POST') {
            $rpc_method = 'iscsi.target.create';
            $params     = [$data];
        } else {
            $rpc_method = 'iscsi.target.query';
            $params     = [[], {}];
        }

    } elsif ($base =~ m{^/iscsi/target/id/(.+)$}) {
        my $id = int($1);
        if ($method eq 'DELETE') {
            $rpc_method = 'iscsi.target.delete';
            $params     = [$id];
        } else {
            $rpc_method = 'iscsi.target.query';
            $params     = [[[ 'id', '=', $id ]], {}];
            $single     = 1;
        }

    } elsif ($base eq '/iscsi/targetextent') {
        if ($method eq 'POST') {
            $rpc_method = 'iscsi.targetextent.create';
            $params     = [$data];
        } else {
            $rpc_method = 'iscsi.targetextent.query';
            my @filter;
            push @filter, [ 'target', '=', int($q{target}) ] if defined $q{target};
            push @filter, [ 'extent', '=', int($q{extent}) ] if defined $q{extent};
            $params = [\@filter, {}];
        }

    } elsif ($base =~ m{^/iscsi/targetextent/id/(.+)$}) {
        $rpc_method = 'iscsi.targetextent.delete';
        # REST call sites pass either a bare boolean or {force=>...} as $data;
        # iscsi.targetextent.delete(id, force=False) is positional (id, bool).
        my $force = (ref($data) eq 'HASH') ? ($data->{force} ? JSON::true : JSON::false)
                  : ($data ? JSON::true : JSON::false);
        $params = [int($1), $force];

    } elsif ($base eq '/iscsi/extent') {
        if ($method eq 'POST') {
            $rpc_method = 'iscsi.extent.create';
            $params     = [$data];
        } else {
            $rpc_method = 'iscsi.extent.query';
            $params     = [[], {}];
        }

    } elsif ($base =~ m{^/iscsi/extent/id/(.+)$}) {
        $rpc_method = 'iscsi.extent.delete';
        # CONFIRMED live 2026-08-31: iscsi.extent.delete(id, remove=False,
        # force=False) is positional, NOT (id, {force=>bool}) — a {force=>...}
        # hash in position 2 fails Pydantic validation on the "remove" field.
        # REST's "force" concept maps to WS's 3rd positional "force"; "remove"
        # (whether to also delete the underlying zvol/file, which the REST
        # path never asked for since free_image deletes the dataset itself
        # afterward) stays false.
        my $force = (ref($data) eq 'HASH' && $data->{force}) ? JSON::true : JSON::false;
        $params = [int($1), JSON::false, $force];

    } elsif ($base eq '/service/reload') {
        $rpc_method = 'service.reload';
        $params     = [$data->{service}];

    } elsif ($base eq '/pool/dataset') {
        if ($method eq 'POST') {
            $rpc_method = 'pool.dataset.create';
            $params     = [$data];
        } else {
            $rpc_method = 'pool.dataset.query';
            my @filter;
            push @filter, [ 'id',   '=', $q{id} ]   if defined $q{id};
            push @filter, [ 'type', '=', $q{type} ] if defined $q{type};
            $params = [\@filter, {}];
        }

    } elsif ($base =~ m{^/pool/dataset/id/(.+)$}) {
        my $id = uri_unescape($1);
        if ($method eq 'DELETE') {
            $rpc_method = 'pool.dataset.delete';
            $params     = [$id, $data // {}];
        } else {
            $rpc_method = 'pool.dataset.query';
            $params     = [[[ 'id', '=', $id ]], {}];
            $single     = 1;
        }

    } elsif ($base eq '/zfs/snapshot') {
        if ($method eq 'POST') {
            $rpc_method = 'zfs.snapshot.create';
            $params     = [$data];
        } else {
            $rpc_method = 'zfs.snapshot.query';
            my @filter;
            push @filter, [ 'dataset', '=', uri_unescape($q{dataset}) ] if defined $q{dataset};
            my %opts;
            $opts{limit} = int($q{limit}) if defined $q{limit};
            $params = [\@filter, \%opts];
        }

    } elsif ($base =~ m{^/zfs/snapshot/id/(.+)$}) {
        $rpc_method = 'zfs.snapshot.delete';
        $params     = [uri_unescape($1)];

    } elsif ($base eq '/zfs/snapshot/rollback') {
        $rpc_method = 'zfs.snapshot.rollback';
        $params     = [$data->{id}, $data->{options}];
    }

    die "TrueNAS WebSocket transport: no JSON-RPC mapping for $method $path\n"
        unless $rpc_method;

    my $resp = _ws_call($scfg, $rpc_method, $params);

    if ($resp->{error}) {
        my $reason = (ref($resp->{error}{data}) eq 'HASH' && $resp->{error}{data}{reason})
            ? " — $resp->{error}{data}{reason}"
            : '';
        my $msg = "TrueNAS API (WebSocket) $rpc_method: "
            . ($resp->{error}{message} // 'unknown error') . $reason;
        _log('err', $msg);
        die "$msg\n";
    }

    my $result = $resp->{result};
    return $single ? (ref($result) eq 'ARRAY' ? $result->[0] : $result) : $result;
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
        my ($bt) = grep { $_->{name} eq $base || $base =~ /:\Q$_->{name}\E$/ } @$targets;
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

    # No existing targets — use first matching portal, no initiator restriction.
    # Force int(): hash keys are always Perl strings; encode_json must see an IV
    # to emit "portal":1 rather than "portal":"1" (rejected by Pydantic v2).
    my ($pid) = keys %our_portal_ids;
    return [ { portal => int($pid), authmethod => 'NONE' } ];
}

sub _clean_groups {
    my ($gs) = @_;
    return [ map {
        my %g = (
            portal     => int($_->{portal}),
            authmethod => $_->{authmethod} // 'NONE',
        );
        # Omit null integer fields — Pydantic v2 (SCALE 25.04+) is strict about types
        $g{initiator} = int($_->{initiator}) if defined $_->{initiator};
        $g{auth}      = int($_->{auth})      if defined $_->{auth};
        \%g
    } @$gs ];
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

    # int() after _log interpolation: string-interpolating $t_id sets its PV flag,
    # turning it into a dual-var that encode_json encodes as a string.
    $state->{$host}{vm_targets}{$vmid} = { id => int($t_id), iqn => $iqn };
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
    return;
}

# Returns true if the QEMU process for $vmid is alive.
# Returns the next unused LUN ID on the given target
sub _next_lun_id {
    my ($scfg, $target_id) = @_;
    my $tes  = _api($scfg, 'GET', "/iscsi/targetextent?target=$target_id") // [];
    my %used = map { $_->{lunid} => 1 } @$tes;
    my $lun  = 0;
    $lun++ while $used{$lun};    # hash-key lookup stringifies $lun; int() restores IV type
    return int($lun);
}

# Returns { extent_id, targetextents, targetextent_id, lun_id, target_id } for a volname,
# or undef if no extent exists.  targetextents is the full array of all associations
# (normally one, but may be >1 if duplicate rows exist from a prior failed alloc_image).
sub _find_extent {
    my ($scfg, $volname) = @_;

    my $extents = _api($scfg, 'GET', '/iscsi/extent') // [];
    my ($ext)   = grep { $_->{name} eq $volname } @$extents;
    return unless $ext;

    my $tes  = _api($scfg, 'GET', "/iscsi/targetextent?extent=$ext->{id}") // [];
    my ($te) = @$tes;

    return {
        extent_id       => $ext->{id},
        naa             => $ext->{naa},
        targetextents   => $tes,
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
    return;
}

# ── PVE::Storage::Plugin interface ───────────────────────────────────────────

sub parse_volname {
    my ($class, $volname) = @_;

    if ($volname =~ /^(vm|base)-(\d+)-disk-\d+$/) {
        my ($prefix, $vmid) = ($1, $2);
        my $isBase = $prefix eq 'base' ? 1 : 0;
        return ('images', $volname, $vmid, undef, undef, $isBase, 'raw');
    }

    # RAM snapshot state volume: vm-<vmid>-state-<snapname>
    # PVE allocates one of these per snapshot when "Include RAM" is selected.
    if ($volname =~ /^vm-(\d+)-state-.+$/) {
        return ('images', $volname, $1, undef, undef, 0, 'raw');
    }

    die "unable to parse TrueNAS volume name '$volname'\n";
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;
    _resolve_token($storeid, $scfg);

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
    _resolve_token($storeid, $scfg);

    die "Unsupported format '$fmt' — only raw is supported\n" if $fmt && $fmt ne 'raw';

    $name //= $class->find_free_diskname($storeid, $scfg, $vmid, 'raw');

    my $prefix = _zvol_prefix($scfg);
    my $zvol   = "$prefix/$name";
    my $size_b = int($size_kb) * 1024;

    _log('info', "alloc_image: creating zvol $zvol ($size_b bytes) for VM $vmid");

    # 1. Create the zvol
    # int() here produces a fresh IV — string interpolation in the log call above
    # sets Perl's POK flag on $size_b, which causes JSON::XS to encode it as a
    # string. SCALE 25.10 strict Pydantic rejects string-typed integers.
    _api($scfg, 'POST', '/pool/dataset', {
        name    => $zvol,
        type    => 'VOLUME',
        volsize => int($size_b),
        sparse  => JSON::true,
    });

    # Steps 2-4 wrapped in eval so the zvol is cleaned up on any failure.
    my ($extent, $target, $lun_id);
    eval {
        # 2. Create the iSCSI extent
        $extent = _api($scfg, 'POST', '/iscsi/extent', {
            name => $name,
            type => 'DISK',
            disk => "zvol/$zvol",
            ro   => JSON::false,
        });

        # 3. Associate extent with the per-VM target
        $target = _resolve_vm_target($scfg, $vmid);
        $lun_id = _next_lun_id($scfg, $target->{id});

        # int() forces fresh IV scalars — decode_json IDs can become dual-vars
        # (string+int) after log interpolation or hash-key lookup, which causes
        # encode_json to emit "7" instead of 7, rejected by Pydantic v2.
        _api($scfg, 'POST', '/iscsi/targetextent', {
            target => int($target->{id}),
            extent => int($extent->{id}),
            lunid  => int($lun_id),
        });
    };

    if (my $err = $@) {
        _log('warning', "alloc_image: partial failure — rolling back: $err");

        # Reverse order, best-effort. Target: only removed if it has no
        # remaining extents (i.e. it was just created for this disk).
        if ($target) {
            eval { _maybe_cleanup_vm_target($scfg, $vmid, $target->{id}) };
        }
        if ($extent) {
            eval { _api($scfg, 'DELETE', "/iscsi/extent/id/$extent->{id}",
                        { force => JSON::true }) };
            _log('warning', "alloc_image rollback: extent delete failed: $@") if $@;
        }
        my $zvol_id = uri_escape($zvol, "^A-Za-z0-9\\-_.~");
        eval { _api($scfg, 'DELETE', "/pool/dataset/id/$zvol_id",
                    { recursive => JSON::true }) };
        _log('warning', "alloc_image rollback: zvol delete failed: $@") if $@;

        die $err;
    }

    _reload_iscsi($scfg);

    _log('info', "alloc_image: $name ready at lun $lun_id on $target->{iqn}");
    return $name;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;
    _resolve_token($storeid, $scfg);

    _log('info', "free_image: removing $volname");

    my ($vmid) = $volname =~ /^(?:vm|base)-(\d+)-/;

    my $ext = _find_extent($scfg, $volname);

    if ($ext) {
        # Step 1: unmap ALL LUN associations for this extent.  Normally there is
        # exactly one targetextent row, but duplicate rows can exist if a prior
        # alloc_image failed partway through and left an orphan.  force=true
        # (bare boolean) is required by SCALE 24.10 when the target has an active
        # session — e.g. removing an unused disk from a running VM.
        for my $te (@{ $ext->{targetextents} // [] }) {
            eval { _api($scfg, 'DELETE', "/iscsi/targetextent/id/$te->{id}", JSON::true) };
            _log('warning', "free_image: could not remove targetextent $te->{id}: $@") if $@;
        }

        # Step 2: delete the extent.  force=true handles any residual session
        # on a single-disk per-VM target (e.g. deleting a detached disk).
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
    return;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $fmt, $ids) = @_;
    _resolve_token($storeid, $scfg);

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
    _resolve_token($storeid, $scfg);

    my $zvol = _zvol_prefix($scfg) . "/$volname";
    my $enc  = uri_escape($zvol, "^A-Za-z0-9\\-_.~");
    my $ds   = _api($scfg, 'GET', "/pool/dataset/id/$enc") // {};
    return $ds->{volsize}{parsed} // 0;
}

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;
    _resolve_token($storeid, $scfg);

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

# Override base-class qemu_blockdev_options to ensure lun is encoded as a JSON
# integer.  PVE::Storage::Plugin does lun => "$3" (string capture from the
# iscsi:// URL regex) which QEMU 9's strict blockdev schema rejects.  We build
# the hash directly from _find_extent so the value is always an IV. (#266)
# REMOVE this override once Proxmox fixes Plugin.pm to use int($3) — verify by
# checking pve-storage changelog for an iscsi lun integer fix, then confirm
# "grep 'lun =>' /usr/share/perl5/PVE/Storage/Plugin.pm" no longer quotes $3.
sub qemu_blockdev_options {
    my ($class, $scfg, $storeid, $volname, $machine_version, $options) = @_;
    _resolve_token($storeid, $scfg);

    my $ext = _find_extent($scfg, $volname);
    die "Volume '$volname' has no iSCSI extent on $scfg->{truenas_host}.\n" unless $ext;
    die "Volume '$volname' is not mapped to any iSCSI target.\n"
        unless defined $ext->{target_id};

    my $t   = _api($scfg, 'GET', "/iscsi/target/id/$ext->{target_id}") // {};
    my $iqn = _basename($scfg) . ":$t->{name}";

    return {
        driver    => 'iscsi',
        portal    => _portal($scfg),
        target    => $iqn,
        lun       => int($ext->{lun_id}),
        transport => 'tcp',
    };
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    _resolve_token($storeid, $scfg);
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
    _resolve_token($storeid, $scfg);
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
        snapshot => { current => 1, snap => 1 },
    };

    my ($vtype, undef, undef, undef, undef, $isBase) = $class->parse_volname($volname);
    my $key = $snapname ? 'snap' : ($isBase ? 'base' : 'current');

    return 1 if $features->{$feature} && $features->{$feature}{$key};
    return;
}

# ── Snapshot support ──────────────────────────────────────────────────────────

# Request a guest filesystem freeze before snapping a running VM's disk.
# Returning 1 causes PVE to ask the QEMU guest agent to freeze IO before the
# TrueNAS API snapshot call, ensuring write-consistency.
sub volume_snapshot_needs_fsfreeze { return 1; }

# Returns the full ZFS path for a volume: "pool[/dataset]/volname"
sub _snap_dataset {
    my ($scfg, $volname) = @_;
    return _zvol_prefix($scfg) . "/$volname";
}

# Returns the full ZFS snapshot ID: "pool[/dataset]/volname@snapname"
sub _snap_id {
    my ($scfg, $volname, $snap) = @_;
    return _zvol_prefix($scfg) . "/$volname\@$snap";
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    _resolve_token($storeid, $scfg);
    my $dataset = _snap_dataset($scfg, $volname);
    _log('info', "snapshot: creating $dataset\@$snap");
    _api($scfg, 'POST', '/zfs/snapshot', { dataset => $dataset, name => $snap });
    return;
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;

    _resolve_token($storeid, $scfg);
    my $id = _snap_id($scfg, $volname, $snap);
    _log('info', "snapshot: deleting $id");

    # The snapshot API requires full URI encoding of the id path segment —
    # unlike the dataset endpoint, it does not accept bare slashes in the path.
    _api($scfg, 'DELETE', "/zfs/snapshot/id/" . uri_escape($id));
    return;
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    _resolve_token($storeid, $scfg);
    my $id = _snap_id($scfg, $volname, $snap);
    _log('info', "snapshot: rolling back to $id");
    _api($scfg, 'POST', '/zfs/snapshot/rollback', {
        id      => $id,
        options => { force => JSON::false, recursive_clones => JSON::false },
    });
    return;
}

# ZFS only permits rollback to the most recent snapshot. If $snap is not the
# newest, list the blocking (newer) snapshots so PVE can report them.
sub volume_rollback_is_possible {
    my ($class, $scfg, $storeid, $volname, $snap, $blockers) = @_;

    my $snaps = $class->volume_snapshot_info($scfg, $storeid, $volname);
    $blockers //= [];
    my $found;

    for my $name (sort { $snaps->{$a}{creation_time} <=> $snaps->{$b}{creation_time} }
                  keys %$snaps) {
        if ($name eq $snap) {
            $found = 1;
        } elsif ($found) {
            push @$blockers, $name;
        }
    }

    die "snapshot '$snap' does not exist on '$volname'\n" if !$found;
    die "can't rollback '$snap' on '$volname' — newer snapshots exist: "
        . join(', ', @$blockers) . "\n"
        if @$blockers;

    return 1;
}

# Returns a hashref of snapshots for $volname, keyed by snapshot name:
#   { 'snapname' => { id => 'pool/vol@snapname', creation_time => $epoch }, ... }
sub volume_snapshot_info {
    my ($class, $scfg, $storeid, $volname) = @_;

    _resolve_token($storeid, $scfg);
    my $dataset = _snap_dataset($scfg, $volname);
    my $enc_ds  = uri_escape($dataset);
    my $snaps   = _api($scfg, 'GET', "/zfs/snapshot?dataset=$enc_ds&limit=500") // [];

    my %result;
    for my $s (@$snaps) {
        # snapshot_name is the part after @; id is the full "dataset@name" string
        my $name  = $s->{snapshot_name}
            // do { (my $n = $s->{id} // '') =~ s/^.*@//; $n };
        my $ctime = $s->{properties}{creation}{rawvalue} // 0;
        $result{$name} = { id => $s->{id}, creation_time => int($ctime) };
    }

    return \%result;
}

1;
