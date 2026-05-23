package PVE::Storage::Custom::TrueNASPlugin;

use strict;
use warnings;
use Data::Dumper;
use IO::File;
use PVE::Tools qw(run_command trim file_read_firstline dir_glob_foreach);
use PVE::Storage::Plugin;
use PVE::JSONSchema qw(get_standard_option);
use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);
use LWP::UserAgent;
use HTTP::Request;
use XML::Simple;

use base qw(PVE::Storage::Plugin);

# Configuration

# API version
sub api {
    return 1;
}

sub type {
    return 'truenas';
}

sub plugindata {
    return {
    content => [ {images => 1}, { images => 1 }],
    };
}

sub properties {
    return {
    freenas_user => {
        description => "FreeNAS API Username",
        type => 'string',
    },
    freenas_password => {
        description => "FreeNAS API Password",
        type => 'string',
    },
    freenas_use_ssl => {
        description => "FreeNAS API access via SSL",
        type => 'boolean',
    },
    freenas_apiv4_host => {
        description => "FreeNAS API Host",
        type => 'string',
    },
    # this will disable write caching on comstar and istgt.
    # it is not implemented for iet. iet blockio always operates with
    # writethrough caching when not in readonly mode
    nowritecache => {
        description => "disable write caching on the target",
        type => 'boolean',
    },
    };
}

sub options {
    return {
    nodes => { optional => 1 },
    disable => { optional => 1 },
    portal => { fixed => 1 },
    target => { fixed => 0 },
    pool => { fixed => 0 },
    blocksize => { fixed => 1 },
    iscsiprovider => { fixed => 1 },
    nowritecache => { optional => 1 },
    sparse => { optional => 1 },
    freenas_user => { optional => 1 },
    freenas_password => { optional => 1 },
    freenas_use_ssl => { optional => 1 },
    freenas_apiv4_host => { optional => 1 },
    content => { optional => 1 },
    bwlimit => { optional => 1 },
    };
}

sub properties {
    return {
    adminserver => {
        description => "Management IP or DNS name of storage.",
        type => 'string', format => 'pve-storage-server',
    },
    login => {
        description => "login",
        type => 'string',
    },
    password => {
        description => "password",
        type => 'string',
    },
    igroup => {
        description => "Initiator group name",
        type => 'string',
    },
    api => {
        description => "API version (7 or 8)",
        type => 'string',
    },
    media => {
        description => "iscsi/multipath",
        type => 'string',
        default => 'multipath',
        enum => ['iscsi', 'multipath'],
    },
    efficiency => {
        description => "Enable Storage Efficiency",
        type => 'boolean',
    },
    };
}

sub options {
    return {
    adminserver => { fixed => 1 },
    login => { fixed => 1 },
    password => { optional => 1 },
    vserver => { optional => 1 },
    aggregate => { fixed => 1 },
        nodes => { optional => 1 },
    disable => { optional => 1 },
    content => { optional => 1 },
    igroup => { optional => 1 },
    api => { optional => 1 },
    media => { optional => 1 },
    target => { optional => 1 },
    shared => { optional => 1 },
    efficiency => { optional => 1 },
    }
}

sub truenas_connect {
    my ($scfg) = @_;

    syslog("info", (caller(0))[3] . " : called");

    my $scheme = $scfg->{freenas_use_ssl} ? "https" : "http";
    my $apihost = defined($scfg->{freenas_apiv4_host}) ? $scfg->{freenas_apiv4_host} : $scfg->{portal};

    if (! defined $freenas_server_list->{$apihost}) {
        $freenas_server_list->{$apihost} = REST::Client->new();
    }
    $freenas_server_list->{$apihost}->setHost($scheme . '://' . $apihost);
    $freenas_server_list->{$apihost}->addHeader('Content-Type', 'application/json');
    $freenas_server_list->{$apihost}->addHeader('Authorization', 'Basic ' . encode_base64($scfg->{freenas_user} . ':' . $scfg->{freenas_password}));
    # If using SSL, don't verify SSL certs
    if ($scfg->{freenas_use_ssl}) {
        $freenas_server_list->{$apihost}->getUseragent()->ssl_opts(verify_hostname => 0);
        $freenas_server_list->{$apihost}->getUseragent()->ssl_opts(SSL_verify_mode => SSL_VERIFY_NONE);
    }
    # Check if the APIs are accessable via the selected host and scheme
    my $code = $freenas_server_list->{$apihost}->request('GET', $apiping)->responseCode();
    if ($code == 200) {                # Successful connection
        syslog("info", (caller(0))[3] . " : REST connection successful to '" . $apihost . "' using the '" . $scheme . "' protocol");
        $runawayprevent = 0;
    } elsif ($runawayprevent > 1) {    # Make sure we are not recursion calling.
        truenas_log_error($freenas_server_list->{$apihost}, "truenas_connect");
        die "Loop recursion prevention";
    } elsif ($code == 302) {           # A 302 from FreeNAS means it doesn't like v1.0 APIs.
        syslog("info", (caller(0))[3] . " : Changing to v2.0 API's");
        $runawayprevent++;
        $apiping =~ s/v1\.0/v2\.0/;
        truenas_connect($scfg);
    } elsif ($code == 307) {           # A 307 from FreeNAS means rediect http to https.
        syslog("info", (caller(0))[3] . " : Redirecting to HTTPS protocol");
        $runawayprevent++;
        $scfg->{freenas_use_ssl} = 1;
        truenas_connect($scfg);
    } else {                           # For now, any other code we fail.
        truenas_log_error($freenas_server_list->{$apihost}, "truenas_connect");
        die "Unable to connect to the FreeNAS API service at '" . $apihost . "' using the '" . $scheme . "' protocol";
    }
    $freenas_rest_connection = $freenas_server_list->{$apihost};
    return;
}

#
# Check to see what FreeNAS version we are running and set
# the FreeNAS.pm to use the correct API version of FreeNAS
#
sub truenas_check {
    my ($scfg, $timeout) = @_;
    my $result = {};
    my $apihost = defined($scfg->{freenas_apiv4_host}) ? $scfg->{freenas_apiv4_host} : $scfg->{portal};

    syslog("info", (caller(0))[3] . " : called");

    if (! defined $freenas_rest_connection->{$apihost}) {
        truenas_connect($scfg);
        eval {
            $result = decode_json($freenas_rest_connection->responseContent());
        };
        if ($@) {
            $result->{'fullversion'} = $freenas_rest_connection->responseContent();
            $result->{'fullversion'} =~ s/^"//g;
        }
        syslog("info", (caller(0))[3] . " : successful : Server version: " . $result->{'fullversion'});
        $result->{'fullversion'} =~ s/^(\w+)\-(\d+)\.(\d+)\-(?:U|BETA)(\d?)\.?(\d?)//;
        my $freenas_version = sprintf("%02d%02d%02d%02d", $2, $3 || 0, $4 || 0, $5 || 0);
        $product_name = $1;
        syslog("info", (caller(0))[3] . " : ". $product_name . " Unformatted Version: " . $freenas_version);
        if ($freenas_version >= 11030100) {
            $freenas_api_version = "v2.0";
            $dev_prefix = "/dev/";
        }
    } else {
        syslog("info", (caller(0))[3] . " : REST Client already initialized");
    }
    syslog("info", (caller(0))[3] . " : Using " . $product_name ." API version " . $freenas_api_version);
    $freenas_api_methods   = $freenas_api_version_matrix->{$freenas_api_version}->{'methods'};
    $freenas_api_variables = $freenas_api_version_matrix->{$freenas_api_version}->{'variables'};
    $freenas_global_config = $freenas_global_config_list->{$apihost} = (!defined($freenas_global_config_list->{$apihost})) ? freenas_iscsi_get_globalconfiguration($scfg) : $freenas_global_config_list->{$apihost};
    return;
}


#
### FREENAS API CALLING ROUTINE ###
#
sub truenas_request {
    my ($scfg, $method, $path, $data) = @_;
    my $apihost = defined($scfg->{freenas_apiv4_host}) ? $scfg->{freenas_apiv4_host} : $scfg->{portal};

    syslog("info", (caller(0))[3] . " : called for host '" . $apihost . "'");

    $method = uc($method);
    if (! $method =~ /^(?>GET|DELETE|POST)$/) {
        syslog("info", (caller(0))[3] . " : Invalid HTTP RESTful service method '$method'");
        die "Invalid HTTP RESTful service method '$method' used.";
    }

    if (! defined $freenas_server_list->{$apihost}) {
        freenas_api_check($scfg);
    }
    $freenas_rest_connection = $freenas_server_list->{$apihost};
    $freenas_global_config = $freenas_global_config_list->{$apihost};
    my $json_data = (defined $data) ? encode_json($data) : undef;
    $freenas_rest_connection->$method($path, $json_data);
    syslog("info", (caller(0))[3] . " : successful");
    return;
}

#
# Writes the Response and Content to SysLog 
#
sub freenas_api_log_error {
    my ($method) = @_;
    syslog("info","[ERROR]FreeNAS::API::" . $method . " : Response code: " . $freenas_rest_connection->responseCode());
    syslog("info","[ERROR]FreeNAS::API::" . $method . " : Response content: " . $freenas_rest_connection->responseContent());
    return 1;
}
