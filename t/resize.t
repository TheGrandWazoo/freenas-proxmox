#!/usr/bin/perl
# volume_resize (#294): grows the zvol via PUT /pool/dataset/id/<zvol> with a
# 1 MiB-aligned integer volsize, returns the new size in KiB (ZFSPoolPlugin
# convention), and refuses snapshots / foreign volume names.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../perl5";

use Test::More;
use JSON ();

use MockTrueNAS;
use PVE::Storage::Custom::TrueNAS;
use PVE::Storage::Custom::TrueNASMultipath;

my $TN = 'PVE::Storage::Custom::TrueNAS';
my $MP = 'PVE::Storage::Custom::TrueNASMultipath';
my $GiB = 1024 ** 3;

sub puts { my ($api) = @_; return grep { $_->[0] eq 'PUT' } @{ $api->calls }; }

subtest 'grows zvol to the requested size' => sub {
    my $api = MockTrueNAS->install();
    my $kb  = $TN->volume_resize(MockTrueNAS::scfg(), 'store', 'vm-100-disk-0', 40 * $GiB, 0);
    is($kb, 40 * 1024 * 1024, 'returns new size in KiB');

    my @p = puts($api);
    is(scalar @p, 1, 'one PUT');
    is($p[0][1], '/pool/dataset/id/tank%2Fvm%2Fvm-100-disk-0', 'targets the zvol');
    is($p[0][2]{volsize}, 40 * $GiB, 'volsize in bytes');
    is(JSON->new->canonical->encode($p[0][2]), '{"volsize":' . (40 * $GiB) . '}',
       'volsize encodes as a JSON integer, not a string');
};

subtest 'rounds up to a 1 MiB boundary' => sub {
    my $api = MockTrueNAS->install();
    my $kb  = $TN->volume_resize(MockTrueNAS::scfg(), 'store', 'vm-100-disk-0', 10 * $GiB + 1536, 0);
    is($kb, 10 * 1024 * 1024 + 1024, 'next whole MiB');
    is((puts($api))[0][2]{volsize} % (1024 * 1024), 0, 'volsize is MiB-aligned');
};

subtest 'cloud-init drive can be resized' => sub {
    my $api = MockTrueNAS->install();
    $TN->volume_resize(MockTrueNAS::scfg(), 'store', 'vm-100-cloudinit', 8 * 1024 * 1024, 0);
    is(scalar(puts($api)), 1, 'PUT issued');
};

subtest 'snapshot resize refused' => sub {
    my $api = MockTrueNAS->install();
    eval { $TN->volume_resize(MockTrueNAS::scfg(), 'store', 'vm-100-disk-0', $GiB, 0, 'snap1') };
    like($@, qr/snapshot/, 'dies');
    is(scalar(puts($api)), 0, 'no API write');
};

subtest 'foreign volume name refused before any API write' => sub {
    my $api = MockTrueNAS->install();
    eval { $TN->volume_resize(MockTrueNAS::scfg(), 'store', '../other-zvol', $GiB, 0) };
    like($@, qr/unable to parse/, 'dies');
    is(scalar(puts($api)), 0, 'no API write');
};

subtest 'multipath: inactive volume only grows the zvol' => sub {
    my $api = MockTrueNAS->install(
        extents       => [ { id => 3, name => 'vm-100-disk-0', naa => '0x6589cfc000000abc' } ],
        targetextents => [ { id => 5, extent => 3, target => 7, lunid => 0 } ],
        targets       => [ { id => 7, name => 'proxmox-vm-100' } ],
    );
    # /dev/mapper/36589cfc000000abc does not exist here, so no rescan is attempted.
    my $kb = $MP->volume_resize(MockTrueNAS::scfg(), 'store', 'vm-100-disk-0', 20 * $GiB, 0);
    is($kb, 20 * 1024 * 1024, 'returns new size in KiB');
    is(scalar(puts($api)), 1, 'zvol PUT issued');
};

done_testing();
