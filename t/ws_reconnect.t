#!/usr/bin/perl
# WebSocket reconnect (#303): TrueNAS closes an idle WebSocket after 30-60s, and
# a pvedaemon worker keeps the cached connection across requests. A cached
# connection is reused only if nothing is pending on it and, once idle for more
# than 10s, it answers core.ping. A read-only call that still hits a closed
# socket is retried once (writes never).

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../perl5";

use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use IO::Handle;

use MockTrueNAS;
use PVE::Storage::Custom::TrueNAS;

my $TN = 'PVE::Storage::Custom::TrueNAS';

# Stand-in for an IO::Socket::SSL handle: a real fd (so select() works) plus
# the ->pending method IO::Socket::SSL adds for TLS-buffered bytes.
package FakeSSL {
    our @ISA = ('IO::Handle');
    sub pending { return 0 }
}

sub sockpair {
    socketpair(my $mine, my $peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
    $peer->autoflush(1);
    return (bless($mine, 'FakeSSL'), $peer);
}

subtest '_ws_quiet' => sub {
    my $quiet = $TN->can('_ws_quiet');
    my ($sock, $peer) = sockpair();
    ok($quiet->({ sock => $sock }), 'nothing pending -> quiet');

    print {$peer} "x";
    ok(!$quiet->({ sock => $sock }), 'unsolicited data while idle (close frame) -> not quiet');

    my ($sock2, $peer2) = sockpair();
    close $peer2;
    ok(!$quiet->({ sock => $sock2 }), 'peer closed (EOF readable) -> not quiet');

    ok(!$quiet->({}), 'missing socket -> not quiet');
};

subtest '_ws_reusable pings only idle connections' => sub {
    my $reusable = $TN->can('_ws_reusable');
    my ($pings, $pong) = (0, sub { return { result => 'pong' } });
    no warnings 'redefine';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
    local *PVE::Storage::Custom::TrueNAS::_ws_call = sub {
        my (undef, $method, undef, $timeout) = @_;
        $pings++ if $method eq 'core.ping';
        is($timeout, 5, 'ping uses the short timeout') if $method eq 'core.ping';
        return $pong->();
    };

    my ($sock, $peer) = sockpair();
    my $scfg = MockTrueNAS::scfg();

    ok($reusable->($scfg, { sock => $sock, last_used => time() }), 'recently used -> reused');
    is($pings, 0, '... without a ping');

    ok($reusable->($scfg, { sock => $sock, last_used => time() - 11 }), 'idle >10s, pong -> reused');
    is($pings, 1, '... after one core.ping');

    $pong = sub { return { error => { message => 'nope' } } };
    ok(!$reusable->($scfg, { sock => $sock, last_used => time() - 11 }), 'ping error -> not reused');

    $pong = sub { die "TrueNAS WebSocket call 'core.ping' to truenas.test timed out\n" };
    ok(!$reusable->($scfg, { sock => $sock, last_used => time() - 11 }),
       'ping timeout (half-open connection) -> not reused');

    print {$peer} "x";
    $pings = 0;
    ok(!$reusable->($scfg, { sock => $sock, last_used => time() - 11 }), 'not quiet -> not reused');
    is($pings, 0, '... and not pinged');
};

# Stubs the transport under _api_ws: _ws_connect counts reconnects, _ws_call
# fails the first $fail_times calls with $err and then succeeds.
sub stub_transport {
    my (%o) = @_;
    my $s = { connects => 0, calls => [] };
    no warnings 'redefine';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
    *PVE::Storage::Custom::TrueNAS::_ws_connect = sub { $s->{connects}++; return {}; };
    *PVE::Storage::Custom::TrueNAS::_ws_call = sub {
        my (undef, $method) = @_;
        push @{ $s->{calls} }, $method;
        die $o{err} if @{ $s->{calls} } <= ($o{fail_times} // 0);
        return { result => $o{result} // {} };
    };
    return $s;
}

my $closed = "TrueNAS WebSocket connection to truenas.test closed unexpectedly during call 'x'\n";

subtest 'read-only call is retried once after the socket closes' => sub {
    MockTrueNAS->install();
    my $s = stub_transport(err => $closed, fail_times => 1, result => { basename => 'iqn.test' });
    my $r = $TN->can('_api_ws')->(MockTrueNAS::scfg(), 'GET', '/iscsi/global');
    is($r->{basename}, 'iqn.test', 'second attempt result returned');
    is_deeply($s->{calls}, ['iscsi.global.config', 'iscsi.global.config'], 'called twice');
    is($s->{connects}, 2, 'reconnected before the retry');
};

subtest 'query is retried, but only once' => sub {
    MockTrueNAS->install();
    my $s = stub_transport(err => $closed, fail_times => 2);
    eval { $TN->can('_api_ws')->(MockTrueNAS::scfg(), 'GET', '/iscsi/extent') };
    like($@, qr/closed unexpectedly/, 'second failure propagates');
    is(scalar @{ $s->{calls} }, 2, 'no third attempt');
};

subtest 'writes are never retried' => sub {
    MockTrueNAS->install();
    my $s = stub_transport(err => $closed, fail_times => 1);
    eval { $TN->can('_api_ws')->(MockTrueNAS::scfg(), 'DELETE', '/iscsi/target/id/7') };
    like($@, qr/closed unexpectedly/, 'error propagates');
    is_deeply($s->{calls}, ['iscsi.target.delete'], 'called exactly once');
};

subtest 'other errors on reads are not retried' => sub {
    MockTrueNAS->install();
    my $s = stub_transport(err => "TrueNAS WebSocket call 'x' to truenas.test timed out after 30s\n",
                           fail_times => 1);
    eval { $TN->can('_api_ws')->(MockTrueNAS::scfg(), 'GET', '/iscsi/global') };
    like($@, qr/timed out/, 'timeout propagates');
    is(scalar @{ $s->{calls} }, 1, 'called exactly once');
};

done_testing();
