package MockTrueNAS;

# In-memory fake of the TrueNAS API for unit tests. Replaces
# PVE::Storage::Custom::TrueNAS::_api (and silences _log) so plugin entry
# points can be exercised without a TrueNAS host or a PVE node.
#
# Usage:
#   my $api = MockTrueNAS->install(
#       extents       => [ { id => 1, name => 'vm-100-disk-0', naa => '0x6589cfc...' } ],
#       targetextents => [ { id => 1, extent => 1, target => 7, lunid => 0 } ],
#       targets       => [ { id => 7, name => 'proxmox-vm-100' } ],
#       datasets      => { 'tank/vm/vm-100-disk-0' => { volsize => { parsed => 1024 } } },
#   );
#   ... call plugin ...
#   $api->calls   # arrayref of [method, path, data]

use strict;
use warnings;

use URI::Escape ();
use PVE::Storage::Custom::TrueNAS;

sub scfg {
    return {
        truenas_host    => 'truenas.test',
        truenas_api_key => 'test-key',
        truenas_pool    => 'tank',
        truenas_dataset => 'vm',
    };
}

sub install {
    my ($class, %db) = @_;
    my $self = bless { db => \%db, calls => [] }, $class;

    no warnings 'redefine';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
    *PVE::Storage::Custom::TrueNAS::_log = sub { push @{ $self->{log} }, [@_]; return; };
    *PVE::Storage::Custom::TrueNAS::_api = sub { return $self->_route(@_); };

    return $self;
}

sub calls { my ($self) = @_; return $self->{calls}; }
sub log   { my ($self) = @_; return $self->{log} // []; }    ## no critic (Subroutines::ProhibitBuiltinHomonyms)

sub _route {
    my ($self, $scfg, $method, $path, $data) = @_;
    push @{ $self->{calls} }, [ $method, $path, $data ];
    my $db = $self->{db};

    if ($method eq 'GET') {
        return { basename => 'iqn.2005-10.org.freenas.ctl' } if $path eq '/iscsi/global';
        return $db->{extents} // [] if $path eq '/iscsi/extent';

        if ($path =~ m{^/iscsi/targetextent\?(extent|target)=(\d+)$}) {
            my ($field, $id) = ($1, $2);
            return [ grep { $_->{$field} == $id } @{ $db->{targetextents} // [] } ];
        }
        if ($path =~ m{^/iscsi/target/id/(\d+)$}) {
            my ($t) = grep { $_->{id} == $1 } @{ $db->{targets} // [] };
            return $t;
        }
        if ($path =~ m{^/pool/dataset/id/(.+)$}) {
            my $name = URI::Escape::uri_unescape($1);
            return $db->{datasets}{$name};
        }
    }

    return if $method eq 'DELETE' || $method eq 'POST' || $method eq 'PUT';

    die "MockTrueNAS: unhandled $method $path\n";
}

1;
