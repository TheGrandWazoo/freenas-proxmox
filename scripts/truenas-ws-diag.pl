#!/usr/bin/perl
# TrueNAS WebSocket JSON-RPC 2.0 diagnostic tool — ADR-012 (#243) live verification.
#
# NOT part of the packaged plugin. Standalone script to verify ADR-012's
# unconfirmed protocol assumptions against a real TrueNAS SCALE 25.04+ host
# before any of this goes into TrueNAS.pm: auth call shape, the method-mapping
# table, and whether TrueNAS Jira NAS-135643 (iscsi.target.query broken on
# JSON-RPC in 25.04.0) reproduces on our own lab nodes.
#
# Read-only: every call below is a *.query/*.config/core.ping method. Nothing
# here creates, deletes, or modifies TrueNAS state.
#
# Requires (apt, Debian trixie): libanyevent-perl libanyevent-websocket-client-perl libjson-perl
#
# Usage:
#   truenas-ws-diag.pl --host 172.31.69.92 --api-key-file /etc/pve/priv/truenas-<storeid>.key [--insecure]
#   truenas-ws-diag.pl --host 172.31.69.92 --api-key <key> --insecure

use strict;
use warnings;
use AnyEvent;
use AnyEvent::WebSocket::Client;
use JSON qw(encode_json decode_json);
use Getopt::Long;

my ($host, $api_key, $api_key_file, $insecure, $timeout);
$timeout = 10;
GetOptions(
    'host=s'         => \$host,
    'api-key=s'      => \$api_key,
    'api-key-file=s' => \$api_key_file,
    'insecure'       => \$insecure,
    'timeout=i'      => \$timeout,
) or die usage();

die usage() unless $host && ($api_key || $api_key_file);

sub usage {
    return "Usage: $0 --host <ip> (--api-key <key> | --api-key-file <path>) [--insecure] [--timeout N]\n";
}

if ($api_key_file) {
    open(my $fh, '<', $api_key_file) or die "Cannot read $api_key_file: $!\n";
    $api_key = do { local $/; <$fh> };
    close $fh;
    $api_key =~ s/\s+\z//;
    die "$api_key_file is empty\n" unless length $api_key;
}

my $url = "wss://$host/api/current";
print "Connecting to $url" . ($insecure ? " (cert verification disabled)" : "") . "...\n";

my $client = AnyEvent::WebSocket::Client->new(
    ssl_no_verify => $insecure ? 1 : 0,
    timeout       => $timeout,
);

my $conn = eval { $client->connect($url)->recv };
if (my $err = $@) {
    die "CONNECT FAILED: $err\n";
}
print "Connected.\n";

my %pending;   # id => condvar
my $next_id = 1;

$conn->on(each_message => sub {
    my ($c, $message) = @_;
    my $body = eval { decode_json($message->body) };
    return unless $body;               # unparseable frame — ignore
    my $id = $body->{id};
    return unless defined $id && $pending{$id};
    (delete $pending{$id})->send($body);
});

$conn->on(finish => sub {
    print "Connection closed by server.\n";
});

sub call {
    my ($method, $params) = @_;
    my $id = $next_id++;
    my $req = { jsonrpc => '2.0', id => $id, method => $method, params => $params // [] };
    print "-> $method " . encode_json($params // []) . "\n";

    my $cv = AnyEvent->condvar;
    $pending{$id} = $cv;
    $conn->send(encode_json($req));

    my $timeout_w = AnyEvent->timer(after => $timeout, cb => sub {
        return unless $pending{$id};
        delete $pending{$id};
        $cv->send({ error => { message => "client timeout after ${timeout}s waiting for id=$id" } });
    });
    my $resp = $cv->recv;
    undef $timeout_w;
    return $resp;
}

sub report {
    my ($label, $resp) = @_;
    if ($resp->{error}) {
        printf("  [FAIL] %-32s %s\n", $label, encode_json($resp->{error}));
    } else {
        my $result  = $resp->{result};
        my $summary = ref($result) eq 'ARRAY' ? scalar(@$result) . ' item(s)'
                    : ref($result) eq 'HASH'  ? '{' . join(',', sort keys %$result) . '}'
                    : defined($result)        ? "$result"
                    :                            '(empty)';
        printf("  [ OK ] %-32s %s\n", $label, $summary);
    }
    return $resp;
}

print "\n== Auth ==\n";

sub auth_ok {
    my ($resp) = @_;
    return 0 unless $resp && !$resp->{error} && $resp->{result};
    my $result = $resp->{result};
    # HASH ref (login_ex): success is signaled by response_type, not just presence of a result
    return (($result->{response_type} // '') eq 'SUCCESS') if ref($result) eq 'HASH';
    # Anything else (JSON true/false decodes to a blessed JSON::PP::Boolean, still truthy here)
    return $result ? 1 : 0;
}

my $auth = call('auth.login_ex', [{ mechanism => 'API_KEY_PLAIN', api_key => $api_key }]);
print "  full result: " . encode_json($auth->{result} // $auth->{error}) . "\n";
if (!auth_ok($auth)) {
    print "  login_ex (no username) did not succeed, retrying with username=>root...\n";
    $auth = call('auth.login_ex', [{ mechanism => 'API_KEY_PLAIN', username => 'root', api_key => $api_key }]);
    print "  full result: " . encode_json($auth->{result} // $auth->{error}) . "\n";
}
if (!auth_ok($auth)) {
    print "  login_ex did not succeed, falling back to legacy auth.login_with_api_key...\n";
    $auth = call('auth.login_with_api_key', [$api_key]);
    print "  full result: " . encode_json($auth->{result} // $auth->{error}) . "\n";
}
report('auth', $auth);
die "Authentication failed against $host — aborting.\n" unless auth_ok($auth);

print "\n== Method mapping checks (read-only queries) ==\n";
report('iscsi.global.config',                   call('iscsi.global.config', []));
report('iscsi.portal.query',                    call('iscsi.portal.query', []));
report('iscsi.target.query (NAS-135643 check)', call('iscsi.target.query', []));
report('iscsi.extent.query',                    call('iscsi.extent.query', []));
report('iscsi.targetextent.query',              call('iscsi.targetextent.query', []));
report('pool.dataset.query (limit 1)',          call('pool.dataset.query', [[], { limit => 1 }]));
report('zfs.snapshot.query (limit 1)',          call('zfs.snapshot.query', [[], { limit => 1 }]));
report('core.ping',                             call('core.ping', []));

print "\nDone. Cross-check any [FAIL] rows against ADR-012's open questions before relying on this transport.\n";
$conn->close;
