#!/usr/bin/perl
# parse_volname: every volume name the plugin (or PVE on its behalf) creates
# must parse, or later operations on it (destroy, resize, regenerate) fail.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../perl5";

use Test::More;

use PVE::Storage::Custom::TrueNAS;

my $TN = 'PVE::Storage::Custom::TrueNAS';

my @ok = (
    # volname                 vmid  isBase
    [ 'vm-100-disk-0',         100,  0 ],
    [ 'base-9000-disk-1',      9000, 1 ],
    [ 'vm-100-state-pre_upg',  100,  0 ],
    [ 'vm-9100-cloudinit',     9100, 0 ],    # #294
    [ 'base-9000-cloudinit',   9000, 1 ],    # #294
);

for my $case (@ok) {
    my ($volname, $vmid, $isBase) = @$case;
    my @r = eval { $TN->parse_volname($volname) };
    is($@, '', "$volname parses");
    is($r[0], 'images', "$volname vtype");
    is($r[1], $volname, "$volname name");
    is($r[2], $vmid,    "$volname owner");
    is($r[5], $isBase,  "$volname isBase");
    is($r[6], 'raw',    "$volname format");
}

for my $bad (qw(vm-100 vm-abc-disk-0 vm-100-cloudinit.qcow2 subvol-100-disk-0 ../vm-100-disk-0)) {
    eval { $TN->parse_volname($bad) };
    like($@, qr/unable to parse/, "$bad rejected");
}

done_testing();
