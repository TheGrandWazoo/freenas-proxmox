#!/usr/bin/perl
# activate_storage log noise (#312): pvestatd activates every storage on every
# ~10 s cycle, so "online" must be logged once per process per storage, and
# again only after deactivate_storage.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../perl5";

use Test::More;

use MockTrueNAS;
use PVE::Storage::Custom::TrueNAS;

my $TN = 'PVE::Storage::Custom::TrueNAS';

sub online_lines {
    my ($api) = @_;
    return scalar grep { $_->[1] =~ /activate_storage: .* online/ } @{ $api->log };
}

subtest 'logged once across repeated activations' => sub {
    my $api = MockTrueNAS->install();
    ok($TN->activate_storage('store', MockTrueNAS::scfg(), {}), 'activates') for 1 .. 5;
    is(online_lines($api), 1, 'one "online" line for five activations');
};

subtest 'each storage logs once' => sub {
    my $api = MockTrueNAS->install();
    $TN->deactivate_storage('store', MockTrueNAS::scfg(), {});
    $TN->activate_storage($_, MockTrueNAS::scfg(), {}) for qw(a b a b);
    is(online_lines($api), 2, 'one line per storeid on the same host');
};

subtest 'logged again after deactivate_storage' => sub {
    my $api = MockTrueNAS->install();
    $TN->deactivate_storage('store', MockTrueNAS::scfg(), {});
    $TN->activate_storage('store', MockTrueNAS::scfg(), {});
    $TN->deactivate_storage('store', MockTrueNAS::scfg(), {});
    $TN->activate_storage('store', MockTrueNAS::scfg(), {});
    is(online_lines($api), 2, 'online after each deactivate');
};

subtest 'failed activation is not marked online' => sub {
    my $api = MockTrueNAS->install();
    $TN->deactivate_storage('store', MockTrueNAS::scfg(), {});
    {
        no warnings 'redefine';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
        local *PVE::Storage::Custom::TrueNAS::_api = sub { die "connection refused\n" };
        eval { $TN->activate_storage('store', MockTrueNAS::scfg(), {}) };
        like($@, qr/connection refused/, 'activation dies');
    }
    $TN->activate_storage('store', MockTrueNAS::scfg(), {});
    is(online_lines($api), 1, 'first successful activation still logs');
};

done_testing();
