package PVE::Storage::Plugin;

# Minimal stand-in for PVE::Storage::Plugin so the TrueNAS plugins can be
# loaded and unit-tested off a Proxmox host. Only what the plugins call on
# the base class at load time (or in tested code paths) is provided.

use strict;
use warnings;

sub new          { return bless {}, shift; }
sub register     { return; }
sub lookup_types { return []; }
sub properties   { return {}; }
sub options      { return {}; }

sub qemu_blockdev_options { return {}; }

1;
