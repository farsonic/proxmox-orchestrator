package PVE::Network::SDN::Orchestrators::Plugin;

# File: /usr/share/perl5/PVE/Network/SDN/Orchestrators/Plugin.pm
# Base plugin class

use strict;
use warnings;

use PVE::Tools;
use PVE::JSONSchema;
use PVE::SectionConfig;

use base qw(PVE::SectionConfig);

# This is critical - the base type
sub type {
    return 'orchestrator';
}

sub private {
    return {
        base => 'PVE::Network::SDN::Orchestrators::Plugin',
    };
}

sub parse_section_header {
    my ($class, $line) = @_;

    if ($line =~ m/^(psm|afc):\s*(\S+)\s*$/) {
        my ($type, $id) = ($1, $2);
        my $errmsg = undef;
        eval { PVE::JSONSchema::pve_verify_configid($id); };
        $errmsg = $@ if $@;
        return ($type, $id, $errmsg);
    }
    return undef;
}

package PVE::Network::SDN::Orchestrators::PsmPlugin;

use strict;
use warnings;

use base qw(PVE::Network::SDN::Orchestrators::Plugin);

sub type {
    return 'psm';
}

sub properties {
    return {
        host => {
            type => 'string',
            format => 'address',
            description => "PSM host/IP address",
        },
        port => {
            type => 'integer',
            minimum => 1,
            maximum => 65535,
            description => "Port number",
        },
        user => {
            type => 'string',
            description => "Username",
        },
        password => {
            type => 'string',
            description => "Password",
        },
        enabled => {
            type => 'boolean',
            description => "Enable/disable",
        },
        verify_ssl => {
            type => 'boolean',
            description => "Verify SSL",
        },
        api_version => {
            type => 'string',
            description => "API version",
        },
        poll_interval_seconds => {
            type => 'integer',
            description => "Poll interval",
        },
        request_timeout => {
            type => 'integer',
            description => "Request timeout",
        },
        reserved_vlans => {
            type => 'string',
            description => "Reserved VLANs",
        },
        reserved_vrf_names => {
            type => 'string',
            description => "Reserved VRF names",
        },
        reserved_zone_names => {
            type => 'string',
            description => "Reserved zone names",
        },
        description => {
            type => 'string',
            description => "Description",
        },
    };
}

sub options {
    return {
        host => { optional => 0 },
        port => { optional => 1 },
        user => { optional => 0 },
        password => { optional => 0 },
        enabled => { optional => 1 },
        verify_ssl => { optional => 1 },
        api_version => { optional => 1 },
        poll_interval_seconds => { optional => 1 },
        request_timeout => { optional => 1 },
        reserved_vlans => { optional => 1 },
        reserved_vrf_names => { optional => 1 },
        reserved_zone_names => { optional => 1 },
        description => { optional => 1 },
    };
}

__PACKAGE__->register();

PVE::Network::SDN::Orchestrators::Plugin->init();

1;
