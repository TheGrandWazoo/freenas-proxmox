#!/usr/bin/perl
# status() polling cost (#310): pvestatd calls status() every ~10 s on every
# node. It must fetch only the pool root dataset, without its children, on
# both transports — the WS shim has to carry extra.retrieve_children through.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../perl5";

use Test::More;
use JSON;

use MockTrueNAS;
use PVE::Storage::Custom::TrueNAS;

my $TN = 'PVE::Storage::Custom::TrueNAS';

subtest 'status() reports the pool root, without children' => sub {
    my $api = MockTrueNAS->install(datasets => {
        tank => { name => 'tank', used => { parsed => 300 }, available => { parsed => 700 } },
    });
    my $scfg = { %{ MockTrueNAS::scfg() }, truenas_pool => 'tank/proxmox' };

    my @r = $TN->status('store', $scfg, {});
    is_deeply(\@r, [ 1000, 700, 300, 1 ], '(total, free, used, active) from the pool root');

    my @gets = grep { $_->[1] =~ m{^/pool/dataset} } @{ $api->calls };
    is(scalar @gets, 1, 'one dataset call');
    is($gets[0][1], '/pool/dataset/id/tank?extra.retrieve_children=false',
        '/id/ form with retrieve_children=false (not ?id=, which CORE answers with [])');
};

subtest 'status() dies when the pool is missing' => sub {
    MockTrueNAS->install(datasets => {});
    eval { $TN->status('store', MockTrueNAS::scfg(), {}) };
    like($@, qr/Pool dataset 'tank' not found/, 'dies');
};

# Runs _api_ws with the transport stubbed out and returns the JSON-RPC call.
sub ws_call_for {
    my ($method, $path) = @_;
    my @sent;
    no warnings 'redefine';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
    local *PVE::Storage::Custom::TrueNAS::_ws_connect = sub { return; };
    local *PVE::Storage::Custom::TrueNAS::_ws_call    = sub {
        my (undef, $rpc, $params) = @_;
        push @sent, [ $rpc, $params ];
        return { result => [ { name => 'tank' } ] };
    };
    $TN->can('_api_ws')->(MockTrueNAS::scfg(), $method, $path);
    return $sent[0];
}

subtest 'WS shim maps extra.retrieve_children into query options' => sub {
    my ($rpc, $params) = @{ ws_call_for('GET', '/pool/dataset/id/tank?extra.retrieve_children=false') };
    is($rpc, 'pool.dataset.query', 'method');
    is_deeply($params->[0], [ [ 'id', '=', 'tank' ] ], 'filter on the id, query string stripped');
    ok(JSON::is_bool($params->[1]{extra}{retrieve_children}), 'value is a JSON boolean');
    ok(!$params->[1]{extra}{retrieve_children}, 'retrieve_children is false');

    (undef, $params) = @{ ws_call_for('GET', '/pool/dataset?id=tank&extra.retrieve_children=false') };
    ok(!$params->[1]{extra}{retrieve_children}, 'same on the filtered list form');
};

subtest 'WS shim sends empty options when there are none' => sub {
    my (undef, $params) = @{ ws_call_for('GET', '/pool/dataset/id/tank%2Fvm%2Fvm-100-disk-0') };
    is_deeply($params, [ [ [ 'id', '=', 'tank/vm/vm-100-disk-0' ] ], {} ], 'unchanged for other callers');

    (undef, $params) = @{ ws_call_for('GET', '/pool/dataset?type=VOLUME') };
    is_deeply($params->[1], {}, 'list form unchanged');
};

done_testing();
