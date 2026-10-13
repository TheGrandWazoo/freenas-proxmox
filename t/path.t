#!/usr/bin/perl
# path() contract tests for both plugins. PVE expects ($path, $owner_vmid, $vtype);
# callers like pvesm free, GUI Remove and qm destroy rely on the owner/vtype
# even for volumes that cannot be opened.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../perl5";

use Test::More;

use MockTrueNAS;
use PVE::Storage::Custom::TrueNAS;
use PVE::Storage::Custom::TrueNASMultipath;

my $TN = 'PVE::Storage::Custom::TrueNAS';
my $MP = 'PVE::Storage::Custom::TrueNASMultipath';

my %mapped = (
    extents       => [ { id => 3, name => 'vm-100-disk-0', naa => '0x6589cfc000000abc' } ],
    targetextents => [ { id => 5, extent => 3, target => 7, lunid => 2 } ],
    targets       => [ { id => 7, name => 'proxmox-vm-100' } ],
);

subtest 'TrueNAS: mapped volume returns iscsi:// path' => sub {
    MockTrueNAS->install(%mapped);
    my ($path, $owner, $vtype) = $TN->path(MockTrueNAS::scfg(), 'vm-100-disk-0', 'store');
    is($path, 'iscsi://truenas.test/iqn.2005-10.org.freenas.ctl:proxmox-vm-100/2', 'path');
    is($owner, 100,      'owner is the VMID');
    is($vtype, 'images', 'vtype');
};

# #292: an orphaned zvol (no extent) must still report owner/vtype so PVE can delete it.
subtest 'TrueNAS: extent-less zvol returns placeholder, not die (#292)' => sub {
    my $api = MockTrueNAS->install(extents => []);
    my ($path, $owner, $vtype) = eval { $TN->path(MockTrueNAS::scfg(), 'vm-101-disk-1', 'store') };
    is($@, '', 'does not die');
    is($path, 'iscsi://truenas.test/unmapped/vm-101-disk-1', 'placeholder path');
    is($owner, 101,      'owner is the VMID');
    is($vtype, 'images', 'vtype');
    ok((grep { $_->[0] eq 'warning' } @{ $api->log }), 'logs a warning');
};

subtest 'TrueNAS: extent with no target mapping returns placeholder (#292)' => sub {
    MockTrueNAS->install(
        extents       => [ { id => 3, name => 'vm-102-disk-0' } ],
        targetextents => [],
    );
    my ($path, $owner) = eval { $TN->path(MockTrueNAS::scfg(), 'vm-102-disk-0', 'store') };
    is($@, '', 'does not die');
    like($path, qr{/unmapped/vm-102-disk-0$}, 'placeholder path');
    is($owner, 102, 'owner is the VMID');
};

subtest 'TrueNAS: activate_volume still dies for extent-less zvol' => sub {
    MockTrueNAS->install(extents => []);
    eval { $TN->activate_volume('store', MockTrueNAS::scfg(), 'vm-101-disk-1') };
    like($@, qr/has no iSCSI extent/, 'activate_volume dies');
};

subtest 'TrueNAS: qemu_blockdev_options still dies for extent-less zvol' => sub {
    MockTrueNAS->install(extents => []);
    eval { $TN->qemu_blockdev_options(MockTrueNAS::scfg(), 'store', 'vm-101-disk-1') };
    like($@, qr/has no iSCSI extent/, 'qemu_blockdev_options dies');
};

# #291: qm destroy compares the owner to the VMID; the LUN id here made it skip every disk.
subtest 'Multipath: mapped volume returns owner VMID and vtype (#291)' => sub {
    MockTrueNAS->install(%mapped);
    my ($path, $owner, $vtype) = $MP->path(MockTrueNAS::scfg(), 'vm-100-disk-0', 'store');
    is($path, '/dev/mapper/36589cfc000000abc', 'path is the dm-multipath device');
    is($owner, 100,      'owner is the VMID, not the LUN id');
    is($vtype, 'images', 'vtype, not the storeid');
};

subtest 'Multipath: base image owner is the template VMID (#291)' => sub {
    MockTrueNAS->install(
        extents       => [ { id => 4, name => 'base-9000-disk-0', naa => '0x6589cfc000000def' } ],
        targetextents => [ { id => 6, extent => 4, target => 8, lunid => 0 } ],
        targets       => [ { id => 8, name => 'proxmox-vm-9000' } ],
    );
    my (undef, $owner, $vtype) = $MP->path(MockTrueNAS::scfg(), 'base-9000-disk-0', 'store');
    is($owner, 9000,     'owner');
    is($vtype, 'images', 'vtype');
};

subtest 'Multipath: extent-less zvol returns placeholder, not die (#292)' => sub {
    MockTrueNAS->install(extents => []);
    my ($path, $owner, $vtype) = eval { $MP->path(MockTrueNAS::scfg(), 'vm-990-disk-0', 'store') };
    is($@, '', 'does not die');
    is($path, '/dev/mapper/truenas-unmapped-vm-990-disk-0', 'placeholder path');
    is($owner, 990,      'owner is the VMID');
    is($vtype, 'images', 'vtype');
};

subtest 'Multipath: extent with no NAA returns placeholder, not /dev/mapper/3' => sub {
    MockTrueNAS->install(
        extents       => [ { id => 3, name => 'vm-100-disk-0', naa => undef } ],
        targetextents => [ { id => 5, extent => 3, target => 7, lunid => 0 } ],
        targets       => [ { id => 7, name => 'proxmox-vm-100' } ],
    );
    my ($path, $owner) = $MP->path(MockTrueNAS::scfg(), 'vm-100-disk-0', 'store');
    is($path, '/dev/mapper/truenas-unmapped-vm-100-disk-0', 'placeholder path');
    is($owner, 100, 'owner');
};

subtest 'Multipath: activate_volume still dies for extent-less zvol' => sub {
    MockTrueNAS->install(extents => []);
    eval { $MP->activate_volume('store', MockTrueNAS::scfg(), 'vm-990-disk-0') };
    like($@, qr/has no iSCSI extent/, 'activate_volume dies');
};

done_testing();
