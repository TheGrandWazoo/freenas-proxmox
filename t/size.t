#!/usr/bin/perl
# volume_size_info contract: scalar context → size; list context →
# (size, format, used, parent). PVE's content API dies "no format" otherwise.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../perl5";

use Test::More;

use MockTrueNAS;
use PVE::Storage::Custom::TrueNAS;

my $TN = 'PVE::Storage::Custom::TrueNAS';

MockTrueNAS->install(datasets => {
    'tank/vm/vm-100-disk-0' => {
        volsize       => { parsed => 34359738368 },
        usedbydataset => { parsed => 1073741824 },
        used          => { parsed => 2147483648 },
    },
    'tank/vm/vm-100-cloudinit' => {
        volsize => { parsed => 4194304 },
        used    => { parsed => 65536 },
    },
});

subtest 'scalar context returns size' => sub {
    my $size = $TN->volume_size_info(MockTrueNAS::scfg(), 'store', 'vm-100-disk-0');
    is($size, 34359738368, 'size');
};

subtest 'list context returns (size, format, used, parent) (#294)' => sub {
    my @r = $TN->volume_size_info(MockTrueNAS::scfg(), 'store', 'vm-100-disk-0');
    is(scalar @r, 4,          'four values');
    is($r[0], 34359738368,    'size');
    is($r[1], 'raw',          'format');
    is($r[2], 1073741824,     'used prefers usedbydataset');
    ok(!defined $r[3],        'no parent');
};

subtest 'used falls back to used when usedbydataset is absent' => sub {
    my (undef, $fmt, $used) = $TN->volume_size_info(MockTrueNAS::scfg(), 'store', 'vm-100-cloudinit');
    is($fmt,  'raw', 'cloud-init drive has a format');
    is($used, 65536, 'used');
};

subtest 'missing zvol dies instead of reporting size 0' => sub {
    eval { $TN->volume_size_info(MockTrueNAS::scfg(), 'store', 'vm-100-disk-9') };
    like($@, qr/not found/, 'dies');
};

done_testing();
