package PVE::Storage::LunCmd::FreeNAS;

use strict;
use warnings;
use Data::Dumper;
use PVE::SafeSyslog;
use IO::Socket::SSL;

use LWP::UserAgent;
use HTTP::Request;
use REST::Client;
use MIME::Base64;
use JSON;

# Global variable definitions
my $MAX_LUNS = 255;                        # Max LUNS per target on the iSCSI server
my $freenas_server_list = undef;           # API connection HashRef using the IP address of the server
my $freenas_rest_connection = undef;       # Pointer to entry in $freenas_server_list
my $freenas_global_config_list = undef;    # IQN HashRef using the IP address of the server
my $freenas_global_config = undef;         # Pointer to entry in $freenas_global_config_list
my $dev_prefix = "";
my $product_name = undef;
my $apiping = '/api/v1.0/system/version/'; # Initial API method for setup
my $runawayprevent = 0;                    # Recursion prevention variable

# FreeNAS API definitions
my $freenas_api_version = "v1.0";          # Default to v1.0 of the API's
my $freenas_api_methods = undef;           # API Methods Nested HASH Ref
my $freenas_api_variables = undef;         # API Variable Nested HASH Ref
my $truenas_version = undef;
my $truenas_release_type = "Production";

# FreeNAS/TrueNAS (CORE) API Versioning HashRef Matrix
my $freenas_api_version_matrix = {
    "v1.0" => {
        "methods" => {
            "config"       => {
                "resource" => "/api/v1.0/services/iscsi/globalconfiguration/",
            },
            "target"       => {
                "resource" => "/api/v1.0/services/iscsi/target/",
            },
            "extent"       => {
                "resource"  => "/api/v1.0/services/iscsi/extent/",
                "post_body" => {
                    "iscsi_target_extent_type" => "Disk",
                    "iscsi_target_extent_name" => "\$name",
                    "iscsi_target_extent_disk" => "\$device",
                },
            },
            "targetextent" => {
                "resource"  => "/api/v1.0/services/iscsi/targettoextent/",
                "post_body" => {
                    "iscsi_target" => "\$target_id",
                    "iscsi_extent" => "\$extent_id",
                    "iscsi_lunid" => "\$lun_id",
                },
            },
        },
        "variables" => {
            "basename"     => "iscsi_basename",
            "lunid"        => "iscsi_lunid",
            "extentid"     => "iscsi_extent",
            "targetid"     => "iscsi_target",
            "extentpath"   => "iscsi_target_extent_path",
            "extentnaa"    => "iscsi_target_extent_naa",
            "targetname"   => "iscsi_target_name",
        }
    },
    "v2.0" => {
        "methods" => {
            "config"       => {
                "resource" => "/api/v2.0/iscsi/global",
            },
            "target"       => {
                "resource" => "/api/v2.0/iscsi/target/",
            },
            "extent"       => {
                "resource"    => "/api/v2.0/iscsi/extent/",
                "delete_body" => {
                    "remove" => \1,
                    "force"  => \1,
                },
                "post_body"   => {
                    "type"   => "DISK",
                    "name"   => "\$name",
                    "disk"   => "\$device",
                },
            },
            "targetextent" => {
                "resource"    => "/api/v2.0/iscsi/targetextent/",
                "delete_body" => {
                    "force"  => \1,
                },
                "post_body"   => {
                    "target"  => "\$target_id",
                    "extent"  => "\$extent_id",
                    "lunid"   => "\$lun_id",
                },
            },
        },
        "variables" => {
            "basename"     => "basename",
            "lunid"        => "lunid",
            "extentid"     => "extent",
            "targetid"     => "target",
            "extentpath"   => "path",
            "extentnaa"    => "naa",
            "targetname"   => "name",
        },
    },
};


#
#
#
sub get_base {
    return '/dev/zvol';
}


#
# Subroutine called from ZFSPlugin.pm
#
sub run_lun_command {
    my ($scfg, $timeout, $method, @params) = @_;

    syslog("info",(caller(0))[3] . " : $method(@params)");

    if (defined($scfg->{'truenas_token_auth'}) && $scfg->{'truenas_token_auth'}) {
        if (!defined($scfg->{'truenas_secret'})) {
            die "Undefined `truenas_secret` variable.";
        }
    } elsif (!defined($scfg->{'freenas_user'}) || !defined($scfg->{'freenas_password'})) {
        die "Undefined `freenas_user` and/or `freenas_password` variables.";
    }
    if (!defined $freenas_server_list->{defined($scfg->{freenas_apiv4_host}) ? $scfg->{freenas_apiv4_host} : $scfg->{portal}}) {
        freenas_api_check($scfg);
    }

    if($method eq "create_lu") {
        return run_create_lu($scfg, $timeout, $method, @params);
    }
    if($method eq "delete_lu") {
        return run_delete_lu($scfg, $timeout, $method, @params);
    }
    if($method eq "import_lu") {
        return run_create_lu($scfg, $timeout, $method, @params);
    }
    if($method eq "modify_lu") {
        return run_modify_lu($scfg, $timeout, $method, @params);
    }
    if($method eq "add_view") {
        return run_add_view($scfg, $timeout, $method, @params);
    }
    if($method eq "list_view") {
        return run_list_view($scfg, $timeout, $method, @params);
    }
    if($method eq "list_extent") {
        return run_list_extent($scfg, $timeout, $method, @params);
    }
    if($method eq "list_lu") {
        return run_list_lu($scfg, $timeout, $method, "name", @params);
    }

    syslog("error",(caller(0))[3] . " : unknown method $method");
    return;
}

#
#
#
sub run_add_view {
    return '';
}

#
# a modify_lu occur by example on a zvol resize. we just need to destroy and recreate the lun with the same zvol.
# Be careful, the first param is the new size of the zvol, we must shift params
#
sub run_modify_lu {
    my ($scfg, $timeout, $method, @params) = @_;

    syslog("info", (caller(0))[3] . " : called");

    shift(@params);
    run_delete_lu($scfg, $timeout, $method, @params);
    return run_create_lu($scfg, $timeout, $method, @params);
}

#
# 
#
sub run_list_view {
    my ($scfg, $timeout, $method, @params) = @_;

    syslog("info", (caller(0))[3] . " : called");

    return run_list_lu($scfg, $timeout, $method, "lun-id", @params);
}

#
#
# Optimized
sub run_list_lu {
    my ($scfg, $timeout, $method, $result_value_type, @params) = @_;
    my $object = $params[0];
    my $result = undef;
    my $luns = freenas_list_lu($scfg);
    syslog("info", (caller(0))[3] . " : called with (method: '$method'; result_value_type: '$result_value_type'; param[0]: '$object')");

    $object =~ s/^\Q$dev_prefix//;
    syslog("info", (caller(0))[3] . " : TrueNAS object to find: '$object'");
    if (defined($luns->{$object})) {
        my $lu_object = $luns->{$object};
        $result = $result_value_type eq "lun-id" ? $lu_object->{$freenas_api_variables->{'lunid'}} : $dev_prefix . $lu_object->{$freenas_api_variables->{'extentpath'}};
        syslog("info",(caller(0))[3] . " '$object' with key '$result_value_type' found with value: '$result'");
    } else {
        syslog("info", (caller(0))[3] . " '$object' with key '$result_value_type' was not found");
    }
    return $result;
}

#
#
# Optimzed
sub run_list_extent {
    my ($scfg, $timeout, $method, @params) = @_;
    my $object = $params[0];
    syslog("info", (caller(0))[3] . " : called with (method: '$method'; params[0]: '$object')");
    my $result = undef;
    my $luns = freenas_list_lu($scfg);

    $object =~ s/^\Q$dev_prefix//;
    syslog("info", (caller(0))[3] . " TrueNAS object to find: '$object'");
    if (defined($luns->{$object})) {
        my $lu_object = $luns->{$object};
        $result = $lu_object->{$freenas_api_variables->{'extentnaa'}};
        syslog("info",(caller(0))[3] . " '$object' with key '$freenas_api_variables->{'extentnaa'}' found with value: '$result'");
    } else {
        syslog("info",(caller(0))[3] . " '$object' with key '$freenas_api_variables->{'extentnaa'}' was not found");
    }
    return $result;
}

#
#
#
sub run_create_lu {
    my ($scfg, $timeout, $method, @params) = @_;
    my $lun_path  = $params[0];

    syslog("info", (caller(0))[3] . " : called with (method=$method; param[0]=$lun_path)");

    my $lun_id    = freenas_get_first_available_lunid($scfg);

    die "Maximum number of LUNs per target is $MAX_LUNS" if scalar $lun_id >= $MAX_LUNS;
    die "$params[0]: LUN $lun_path exists" if defined(run_list_lu($scfg, $timeout, $method, "name", @params));

    my $target_id = freenas_get_targetid($scfg);
    die "Unable to find the target id for $scfg->{target}" if !defined($target_id);

    # Create the extent
    my $extent = freenas_iscsi_create_extent($scfg, $lun_path);

    # Associate the new extent to the target
    my $link = freenas_iscsi_create_target_to_extent($scfg, $target_id, $extent->{'id'}, $lun_id);

    if (defined($link)) {
       syslog("info","FreeNAS::create_lu(lun_path=$lun_path, lun_id=$lun_id) : successful");
    } else {
       die "Unable to create lun $lun_path";
    }

    return "";
}

#
#
# Optimzied
sub run_delete_lu {
    my ($scfg, $timeout, $method, @params) = @_;
    my $lun_path  = $params[0];

    syslog("info", (caller(0))[3] . " : called with (method: '$method'; param[0]: '$lun_path')");

    my $luns      = freenas_list_lu($scfg);
    my $lun       = undef;
    my $link      = undef;
    $lun_path =~ s/^\Q$dev_prefix//;

    if (defined($luns->{$lun_path})) {
        $lun = $luns->{$lun_path};
        syslog("info",(caller(0))[3] . " lun: '$lun_path' found");
    } else {
        die "Unable to find the lun $lun_path for $scfg->{target}";
    }

    my $target_id = freenas_get_targetid($scfg);
    die "Unable to find the target id for $scfg->{target}" if !defined($target_id);

    # find the target to extent
    my $target2extents = freenas_iscsi_get_target_to_extent($scfg);

    syslog("info", (caller(0))[3] . " : searching for 'targetextent' with (target_id=$target_id; lun_id=$lun->{$freenas_api_variables->{'lunid'}}; extent_id=$lun->{id})");
    foreach my $item (@$target2extents) {
        if($item->{$freenas_api_variables->{'targetid'}} == $target_id &&
           $item->{$freenas_api_variables->{'lunid'}} == $lun->{$freenas_api_variables->{'lunid'}} &&
           $item->{$freenas_api_variables->{'extentid'}} == $lun->{'id'}) {
            $link = $item;
            syslog("info", (caller(0))[3] . " : found 'targetextent'(target_id=$item->{$freenas_api_variables->{'targetid'}}; lun_id=$item->{$freenas_api_variables->{'lunid'}}; extent_id=$item->{$freenas_api_variables->{'extentid'}})");
            last;
        }
    }
    die "Unable to find the link for the lun $lun_path for $scfg->{target}" if !defined($link);

    # Remove the extent
    my $remove_extent = freenas_iscsi_remove_extent($scfg, $lun->{'id'});

    # Remove the link
    my $remove_link = freenas_iscsi_remove_target_to_extent($scfg, $link->{'id'});

    if($remove_link == 1 && $remove_extent == 1) {
        syslog("info", (caller(0))[3] . "(lun_path=$lun_path) : successful");
    } else {
        die "Unable to delete lun $lun_path";
    }

    return "";
}


sub freenas_api_connect {
    my ($scfg) = @_;

    syslog("info", (caller(0))[3] . " : called");

    my $scheme = $scfg->{freenas_use_ssl} ? "https" : "http";
    my $apihost = defined($scfg->{freenas_apiv4_host}) ? $scfg->{freenas_apiv4_host} : $scfg->{portal};

    if (! defined $freenas_server_list->{$apihost}) {
        $freenas_server_list->{$apihost} = REST::Client->new();
    }
    $freenas_server_list->{$apihost}->setHost($scheme . '://' . $apihost);
    $freenas_server_list->{$apihost}->addHeader('Content-Type', 'application/json');
    if (defined($scfg->{'truenas_token_auth'}) && $scfg->{'truenas_token_auth'}) {
        syslog("info", (caller(0))[3] . " : Authentication using Bearer Token Auth");
        $freenas_server_list->{$apihost}->addHeader('Authorization', 'Bearer ' . $scfg->{truenas_secret});
    } else {
        syslog("info", (caller(0))[3] . " : Authentication using Basic Auth");
        $freenas_server_list->{$apihost}->addHeader('Authorization', 'Basic ' . encode_base64($scfg->{freenas_user} . ':' . $scfg->{freenas_password}));
    }
    # If using SSL, don't verify SSL certs
    if ($scfg->{freenas_use_ssl}) {
        $freenas_server_list->{$apihost}->getUseragent()->ssl_opts(verify_hostname => 0);
        $freenas_server_list->{$apihost}->getUseragent()->ssl_opts(SSL_verify_mode => SSL_VERIFY_NONE);
    }
    # Check if the APIs are accessable via the selected host and scheme
    my $api_response = $freenas_server_list->{$apihost}->request('GET', $apiping);
    my $code = $api_response->responseCode();
    my $type = $api_response->responseHeader('Content-Type');
    syslog("info", (caller(0))[3] . " : REST connection header Content-Type:'" . $type . "'");

    # Make sure we are not recursion calling.
    if ($runawayprevent > 2) {
        freenas_api_log_error($freenas_server_list->{$apihost});
        die "Loop recursion prevention";
    # Successful connection
    } elsif ($code == 200 && ($type =~ /^text\/plain/ || $type =~ /^application\/json/)) {
        syslog("info", (caller(0))[3] . " : REST connection successful to '" . $apihost . "' using the '" . $scheme . "' protocol");
        $runawayprevent = 0;
    # A 302 or 200 (We already check for the correct 'type' above with a 200 so why add additional conditionals).
    # So change to v2.0 APIs.
    } elsif ($code == 302 || $code == 200) {
        syslog("info", (caller(0))[3] . " : Changing to v2.0 API's");
        $runawayprevent++;
        $apiping =~ s/v1\.0/v2\.0/;
        freenas_api_connect($scfg);
    # A 307 from FreeNAS means rediect http to https.
    } elsif ($code == 307) {
        syslog("info", (caller(0))[3] . " : Redirecting to HTTPS protocol");
        $runawayprevent++;
        $scfg->{freenas_use_ssl} = 1;
        freenas_api_connect($scfg);
    # For now, any other code we fail.
    } else {
        freenas_api_log_error($freenas_server_list->{$apihost});
        die "Unable to connect to the FreeNAS API service at '" . $apihost . "' using the '" . $scheme . "' protocol";
    }
    $freenas_rest_connection = $freenas_server_list->{$apihost};
    return;
}

#
# Check to see what FreeNAS version we are running and set
# the FreeNAS.pm to use the correct API version of FreeNAS
#
sub freenas_api_check {
    my ($scfg, $timeout) = @_;
    my $result = {};
    my $apihost = defined($scfg->{freenas_apiv4_host}) ? $scfg->{freenas_apiv4_host} : $scfg->{portal};

    syslog("info", (caller(0))[3] . " : called");

    if (! defined $freenas_rest_connection->{$apihost}) {
        freenas_api_connect($scfg);
        eval {
            $result = decode_json($freenas_rest_connection->responseContent());
        };
        if ($@) {
            $result = $freenas_rest_connection->responseContent();
        } else {
            $result = $freenas_rest_connection->responseContent();
        }
        $result =~ s/"//g;
        syslog("info", (caller(0))[3] . " : successful : Server version: " . $result);
        if ($result =~ /^(TrueNAS|FreeNAS)-(\d+)\.(\d+)\-U(\d+)(?(?=\.)\.(\d+))$/) {
            $product_name = $1;
            $truenas_version = sprintf("%02d%02d%02d%02d", $2, $3 || 0, $4 || 0, $5 || 0);
        } elsif ($result =~ /^(TrueNAS)-(\d+)\.(\d+)(?(?=\-U\d+)-U(\d+)|-\w+)(?(?=\.).(\d+))$/) {
            $product_name = $1;
            $truenas_version = sprintf("%02d%02d%02d%02d", $2, $3 || 0, $4 || 0, $6 || 0);
            $truenas_release_type = $5 || "Production";
        } elsif ($result =~ /^(TrueNAS-SCALE)-(\d+)\.(\d+)(?(?=\-)-(\w+))\.(\d+)(?(?=\.)\.(\d+))(?(?=\-)-(\d+))$/) {
            $product_name = $1;
            $truenas_version = sprintf("%02d%02d%02d%02d", $2, $3 || 0, $5 || 0, $7 || 0);
            $truenas_release_type = $4 || "Production";
        } else {
            $product_name = "Unknown";
            $truenas_release_type = "Unknown";
            syslog("error", (caller(0))[3] . " : Could not parse the version of TrueNAS.");
        }
        syslog("info", (caller(0))[3] . " : ". $product_name . " Unformatted Version: " . $truenas_version);
        if ($truenas_version >= 11030100) {
            $freenas_api_version = "v2.0";
            $dev_prefix = "/dev/";
        }
        if ($truenas_release_type ne "Production") {
            syslog("warn", (caller(0))[3] . " : The '" . $product_name . "' release type of '" . $truenas_release_type . "' may not worked due to unsupported changes.");
        }
    } else {
        syslog("info", (caller(0))[3] . " : REST Client already initialized");
    }
    syslog("info", (caller(0))[3] . " : Using " . $product_name . " API version " . $freenas_api_version);
    $freenas_api_methods   = $freenas_api_version_matrix->{$freenas_api_version}->{'methods'};
    $freenas_api_variables = $freenas_api_version_matrix->{$freenas_api_version}->{'variables'};
    $freenas_global_config = $freenas_global_config_list->{$apihost} = (!defined($freenas_global_config_list->{$apihost})) ? freenas_iscsi_get_globalconfiguration($scfg) : $freenas_global_config_list->{$apihost};
    return;
}


#
### FREENAS API CALLING ROUTINE ###
#
sub freenas_api_call {
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
    $freenas_rest_connection->request($method, $path, $json_data);
    syslog("info", (caller(0))[3] . " : successful");
    return;
}

#
# Writes the Response and Content to SysLog 
#
sub freenas_api_log_error {
    my ($rest_connection) = @_;
    my $connection = ((defined $rest_connection) ? $rest_connection : $freenas_rest_connection);
    syslog("info","[ERROR]FreeNAS::API::" . (caller(1))[3] . " : Response code: " . $connection->responseCode());
    syslog("info","[ERROR]FreeNAS::API::" . (caller(1))[3] . " : Response content: " . $connection->responseContent());
    return 1;
}

#
#
#
sub freenas_iscsi_get_globalconfiguration {
    my ($scfg) = @_;

    syslog("info", (caller(0))[3] . " : called");

    freenas_api_call($scfg, 'GET', $freenas_api_methods->{'config'}->{'resource'}, $freenas_api_methods->{'config'}->{'get'});
    my $code = $freenas_rest_connection->responseCode();
    if ($code == 200) {
        my $result = decode_json($freenas_rest_connection->responseContent());
        syslog("info", (caller(0))[3] . " : target_basename=" . $result->{$freenas_api_variables->{'basename'}});
        return $result;
    } else {
        freenas_api_log_error();
        return;
    }
}

#
# Returns a list of all extents.
# http://api.freenas.org/resources/iscsi/index.html#get--api-v1.0-services-iscsi-extent-
#
sub freenas_iscsi_get_extent {
    my ($scfg) = @_;

    syslog("info", (caller(0))[3] . " : called");

    freenas_api_call($scfg, 'GET', $freenas_api_methods->{'extent'}->{'resource'} . "?limit=0", $freenas_api_methods->{'extent'}->{'get'});
    my $code = $freenas_rest_connection->responseCode();
    if ($code == 200) {
        my $result = decode_json($freenas_rest_connection->responseContent());
        syslog("info", (caller(0))[3] . " : successful");
        return $result;
    } else {
        freenas_api_log_error();
        return;
    }
}

#
# Create an extent on FreeNas
# http://api.freenas.org/resources/iscsi/index.html#create-resource
# Parameters:
#   - target config (scfg)
#   - lun_path
#
sub freenas_iscsi_create_extent {
    my ($scfg, $lun_path) = @_;

    syslog("info", (caller(0))[3] . " : called with (lun_path=$lun_path)");

    my $name = $lun_path;
    $name  =~ s/^.*\///; # all from last /

    my $pool = $scfg->{'pool'};
    # If TrueNAS-SCALE the slashes (/) need to be converted to dashes (-)
    if ($product_name eq "TrueNAS-SCALE") {
        $pool =~ s/\//-/g;
        syslog("info", (caller(0))[3] . " : TrueNAS-SCALE slash to dash conversion '" . $pool ."'");
    }
    $name  = $pool . ($product_name eq "TrueNAS-SCALE" ? '-' : '/') . $name;
    syslog("info", (caller(0))[3] . " : " . $product_name . " extent '". $name . "'");

    my $device = $lun_path;
    $device =~ s/^\/dev\///; # strip /dev/

    my $post_body = {};
    while ((my $key, my $value) = each %{$freenas_api_methods->{'extent'}->{'post_body'}}) {
        $post_body->{$key} = ($value =~ /^\$.+$/) ? eval $value : $value;
    }

    freenas_api_call($scfg, 'POST', $freenas_api_methods->{'extent'}->{'resource'}, $post_body);
    my $code = $freenas_rest_connection->responseCode();
    if ($code == 200 || $code == 201) {
        my $result = decode_json($freenas_rest_connection->responseContent());
        syslog("info", "FreeNAS::API::create_extent(lun_path=" . $result->{$freenas_api_variables->{'extentpath'}} . ") : successful");
        return $result;
    } else {
        freenas_api_log_error();
        return;
    }
}

#
# Remove an extent by it's id
# http://api.freenas.org/resources/iscsi/index.html#delete-resource
# Parameters:
#    - scfg
#    - extent_id
#
sub freenas_iscsi_remove_extent {
    my ($scfg, $extent_id) = @_;

    syslog("info", (caller(0))[3] . " : called with (extent_id=$extent_id)");
    freenas_api_call($scfg, 'DELETE', $freenas_api_methods->{'extent'}->{'resource'} . (($freenas_api_version eq "v2.0") ? "id/" : "") . "$extent_id/", $freenas_api_methods->{'extent'}->{'delete_body'});
    my $code = $freenas_rest_connection->responseCode();
    if ($code == 200 || $code == 204) {
        syslog("info", (caller(0))[3] . "(extent_id=$extent_id) : successful");
        return 1;
    } else {
        freenas_api_log_error();
        return 0;
    }
}

#
# Returns a list of all targets
# http://api.freenas.org/resources/iscsi/index.html#get--api-v1.0-services-iscsi-target-
#
sub freenas_iscsi_get_target {
    my ($scfg) = @_;

    syslog("info", (caller(0))[3] . " : called");

    freenas_api_call($scfg, 'GET', $freenas_api_methods->{'target'}->{'resource'} . "?limit=0", $freenas_api_methods->{'target'}->{'get'});
    my $code = $freenas_rest_connection->responseCode();
    if ($code == 200) {
        my $result = decode_json($freenas_rest_connection->responseContent());
        syslog("info", (caller(0))[3] . " : successful");
        return $result;
    } else {
        freenas_api_log_error();
        return;
    }
}

#
# Returns a list of associated extents to targets
# http://api.freenas.org/resources/iscsi/index.html#get--api-v1.0-services-iscsi-targettoextent-
#
sub freenas_iscsi_get_target_to_extent {
    my ($scfg) = @_;

    syslog("info", (caller(0))[3] . " : called");

    freenas_api_call($scfg, 'GET', $freenas_api_methods->{'targetextent'}->{'resource'} . "?limit=0", $freenas_api_methods->{'targetextent'}->{'get'});
    my $code = $freenas_rest_connection->responseCode();
    if ($code == 200) {
        my $result = decode_json($freenas_rest_connection->responseContent());
        syslog("info", (caller(0))[3] . " : successful");
        # If 'iscsi_lunid' is undef then it is set to 'Auto' in FreeNAS
        # which should be '0' in our eyes.
        # This gave Proxmox 5.x and FreeNAS 11.1 a few issues.
        foreach my $item (@$result) {
            if (!defined($item->{$freenas_api_variables->{'lunid'}})) {
                $item->{$freenas_api_variables->{'lunid'}} = 0;
                syslog("info", (caller(0))[3] . " : change undef iscsi_lunid to 0");
            }
        }
        return $result;
    } else {
        freenas_api_log_error();
        return;
    }
}

#
# Associate a FreeNas extent to a FreeNas Target
# http://api.freenas.org/resources/iscsi/index.html#post--api-v1.0-services-iscsi-targettoextent-
# Parameters:
#   - target config (scfg)
#   - FreeNas Target ID
#   - FreeNas Extent ID
#   - Lun ID
#
sub freenas_iscsi_create_target_to_extent {
    my ($scfg, $target_id, $extent_id, $lun_id) = @_;

    syslog("info", (caller(0))[3] . " : called with (target_id=$target_id, extent_id=$extent_id, lun_id=$lun_id)");

    my $post_body = {};
    while ((my $key, my $value) = each %{$freenas_api_methods->{'targetextent'}->{'post_body'}}) {
        $post_body->{$key} = ($value =~ /^\$.+$/) ? eval $value : $value;
    }

    freenas_api_call($scfg, 'POST', $freenas_api_methods->{'targetextent'}->{'resource'}, $post_body);
    my $code = $freenas_rest_connection->responseCode();
    if ($code == 200 || $code == 201) {
        my $result = decode_json($freenas_rest_connection->responseContent());
        syslog("info", (caller(0))[3] . "(target_id=$target_id, extent_id=$extent_id, lun_id=$lun_id) : successful");
        return $result;
    } else {
        freenas_api_log_error();
        return;
    }
}

#
# Remove a Target to extent by it's id
# http://api.freenas.org/resources/iscsi/index.html#delete--api-v1.0-services-iscsi-targettoextent-(int-id)-
# Parameters:
#    - scfg
#    - link_id
#
sub freenas_iscsi_remove_target_to_extent {
    my ($scfg, $link_id) = @_;

    syslog("info", (caller(0))[3] . " : called with (link_id=$link_id)");

    if ($freenas_api_version eq "v2.0") {
        syslog("info", (caller(0))[3] . "(link_id=$link_id) : V2.0 API's so NOT Needed...successful");
        return 1;
    }

    freenas_api_call($scfg, 'DELETE', $freenas_api_methods->{'targetextent'}->{'resource'} . (($freenas_api_version eq "v2.0") ? "id/" : "") . "$link_id/", $freenas_api_methods->{'targetextent'}->{'delete_body'});
    my $code = $freenas_rest_connection->responseCode();
    if ($code == 200 || $code == 204) {
        syslog("info", (caller(0))[3] . "(link_id=$link_id) : successful");
        return 1;
    } else {
        freenas_api_log_error();
        return 0;
    }
}

#
# Returns all luns associated to the current target defined by $scfg->{target}
# This method returns an array reference like "freenas_iscsi_get_extent" do
# but with an additionnal hash entry "iscsi_lunid" retrieved from "freenas_iscsi_get_target_to_extent"
#
sub freenas_list_lu {
    my ($scfg) = @_;

    syslog("info", (caller(0))[3] . " : called");

    my $targets   = freenas_iscsi_get_target($scfg);
    my $target_id = freenas_get_targetid($scfg);

    my %lun_hash;
    my $iscsi_lunid = undef;

    if(defined($target_id)) {
        my $target2extents = freenas_iscsi_get_target_to_extent($scfg);
        my $extents        = freenas_iscsi_get_extent($scfg);

        foreach my $item (@$target2extents) {
            if($item->{$freenas_api_variables->{'targetid'}} == $target_id) {
                foreach my $node (@$extents) {
                    if($node->{'id'} == $item->{$freenas_api_variables->{'extentid'}}) {
                        if ($item->{$freenas_api_variables->{'lunid'}} =~ /(\d+)/) {
                            if (defined($node)) {
                                $node->{$freenas_api_variables->{'lunid'}} .= "$1";
                                $lun_hash{$node->{$freenas_api_variables->{'extentpath'}}} = $node;
                            }
                            last;
                        } else {
                            syslog("warn", (caller(0))[3] . " : iscsi_lunid did not pass tainted testing");
                        }
                    }
                }
            }
        }
    }
    syslog("info", (caller(0))[3] . " : successful");
    return \%lun_hash;
}

#
# Returns the first available "lunid" (in all targets namespaces)
#
sub freenas_get_first_available_lunid {
    my ($scfg) = @_;

    syslog("info", (caller(0))[3] . " : called");

    my $target_id      = freenas_get_targetid($scfg);
    my $target2extents = freenas_iscsi_get_target_to_extent($scfg);
    my @luns           = ();

    foreach my $item (@$target2extents) {
        push(@luns, $item->{$freenas_api_variables->{'lunid'}}) if ($item->{$freenas_api_variables->{'targetid'}} == $target_id);
    }

    my @sorted_luns =  sort {$a <=> $b} @luns;
    my $lun_id      = 0;

    # find the first hole, if not, give the +1 of the last lun
    foreach my $lun (@sorted_luns) {
        last if $lun != $lun_id;
        $lun_id = $lun_id + 1;
    }

    syslog("info", (caller(0))[3] . " : $lun_id");
    return $lun_id;
}

#
# Returns the target id on FreeNas of the currently configured target of this PVE storage
#
sub freenas_get_targetid {
    my ($scfg) = @_;

    syslog("info", (caller(0))[3] . " : called");

    my $targets   = freenas_iscsi_get_target($scfg);
    my $target_id = undef;

    foreach my $target (@$targets) {
        my $iqn = $freenas_global_config->{$freenas_api_variables->{'basename'}} . ':' . $target->{$freenas_api_variables->{'targetname'}};
        if($iqn eq $scfg->{target}) {
            $target_id = $target->{'id'};
            last;
        }
    }
    syslog("info", (caller(0))[3] . " : successful : $target_id");
    return $target_id;
}


1;
