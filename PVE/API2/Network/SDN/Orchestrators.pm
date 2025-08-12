package PVE::API2::Network::SDN::Orchestrators;

# File: /usr/share/perl5/PVE/API2/Network/SDN/Orchestrators.pm

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools qw(extract_param);
use PVE::Network::SDN::Orchestrators;
use PVE::JSONSchema qw(get_standard_option);
use PVE::RPCEnvironment;
use PVE::RESTHandler;
use PVE::Exception qw(raise raise_param_exc);

use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    description => "List SDN orchestrators.",
    permissions => {
        description => "Read access to SDN orchestrators.",
        user => 'all',
    },
    parameters => {
        additionalProperties => 0,
        properties => {},
    },
    returns => {
        type => 'array',
        items => {
            type => "object",
            properties => {
                id => { type => 'string' },
                type => { type => 'string' },
                host => { type => 'string' },
                enabled => { type => 'boolean' },
                port => { type => 'string' },
                user => { type => 'string' },
                description => { type => 'string' },
            },
        },
        links => [ { rel => 'child', href => "{id}" } ],
    },
    code => sub {
        my ($param) = @_;

        my $cfg = PVE::Network::SDN::Orchestrators::config();
        
        my @list = ();
        foreach my $id (sort keys %{$cfg->{ids}}) {
            my $orch = $cfg->{ids}->{$id};
            push @list, {
                id => $id,
                type => $orch->{type} || 'psm',
                host => $orch->{host},
                user => $orch->{user},
                enabled => $orch->{enabled} ? 1 : 0,
                port => $orch->{port},
                description => $orch->{description},
            };
        }
        
        return \@list;
    }
});

__PACKAGE__->register_method({
    name => 'read',
    path => '{id}',
    method => 'GET',
    description => "Read orchestrator configuration.",
    permissions => {
        user => 'all',
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            id => {
                type => 'string',
                format => 'pve-configid',
            },
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;

        my $cfg = PVE::Network::SDN::Orchestrators::config();
        my $id = $param->{id};
        
        my $orch = PVE::Network::SDN::Orchestrators::sdn_orchestrators_config($cfg, $id);
        
        return {
            id => $id,
            %$orch,
        };
    }
});

__PACKAGE__->register_method({
    name => 'create',
    protected => 1,
    path => '',
    method => 'POST',
    description => "Create a new SDN orchestrator.",
    permissions => {
        check => ['perm', '/sdn', ['SDN.Allocate']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            id => {
                type => 'string',
                format => 'pve-configid',
                description => "Orchestrator ID",
            },
            type => {
                type => 'string',
                enum => ['psm', 'afc'],
                description => "Orchestrator type",
            },
            host => {
                type => 'string',
                format => 'address',
                description => "Host/IP address",
            },
            port => {
                type => 'integer',
                minimum => 1,
                maximum => 65535,
                optional => 1,
                default => 443,
                description => "Port",
            },
            user => {
                type => 'string',
                description => "Username",
            },
            password => {
                type => 'string',
                optional => 1,
                description => "Password",
            },
            # AFC-specific parameters
            api_token => {
                type => 'string',
                optional => 1,
                description => "API token for AFC authentication",
            },
            fabric_name => {
                type => 'string',
                optional => 1,
                description => "AFC fabric name",
            },
            management_vlan => {
                type => 'integer',
                minimum => 1,
                maximum => 4094,
                optional => 1,
                description => "Management VLAN ID",
            },
            sync_mode => {
                type => 'string',
                enum => ['full', 'incremental'],
                optional => 1,
                default => 'incremental',
                description => "Synchronization mode",
            },
            # Common parameters
            enabled => {
                type => 'boolean',
                optional => 1,
                default => 1,
                description => "Enable/disable",
            },
            verify_ssl => {
                type => 'boolean',
                optional => 1,
                default => 0,
                description => "Verify SSL",
            },
            api_version => {
                type => 'string',
                optional => 1,
                default => 'v1',
                description => "API version",
            },
            poll_interval_seconds => {
                type => 'integer',
                minimum => 10,
                maximum => 3600,
                optional => 1,
                default => 60,
                description => "Polling interval in seconds",
            },
            request_timeout => {
                type => 'integer',
                minimum => 5,
                maximum => 300,
                optional => 1,
                default => 10,
                description => "Request timeout in seconds",
            },
            reserved_vlans => {
                type => 'string',
                optional => 1,
                description => "Comma-separated list of reserved VLAN IDs",
            },
            reserved_vrf_names => {
                type => 'string',
                optional => 1,
                description => "Comma-separated list of reserved VRF names",
            },
            reserved_zone_names => {
                type => 'string',
                optional => 1,
                description => "Comma-separated list of reserved zone names",
            },
            description => {
                type => 'string',
                optional => 1,
                maxLength => 256,
                description => "Description",
            },
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        my $id = extract_param($param, 'id');
        my $type = $param->{type};
        
        PVE::Network::SDN::Orchestrators::lock_config(sub {
            my $cfg = PVE::Network::SDN::Orchestrators::config();
            
            die "orchestrator '$id' already exists\n" if $cfg->{ids}->{$id};
            
            # Type-specific validation and defaults
            if ($type eq 'afc') {
                # AFC requires either password or API token
                if (!$param->{password} && !$param->{api_token}) {
                    die "AFC orchestrator requires either password or API token\n";
                }
                # AFC defaults
                $param->{verify_ssl} //= 1;  # AFC defaults to SSL verification
                $param->{poll_interval_seconds} //= 120;  # AFC defaults to 2 minutes
                $param->{request_timeout} //= 30;  # AFC defaults to 30 seconds
            } elsif ($type eq 'psm') {
                # PSM requires password
                die "PSM orchestrator requires password\n" if !$param->{password};
                # PSM defaults (keep existing)
                $param->{verify_ssl} //= 0;
                $param->{poll_interval_seconds} //= 60;
                $param->{request_timeout} //= 10;
            }
            
            # Set common defaults if not provided
            $param->{enabled} //= 1;
            $param->{port} //= 443;
            $param->{api_version} //= 'v1';
            
            $cfg->{ids}->{$id} = $param;
            
            # Update order
            my $max_order = 0;
            foreach my $v (values %{$cfg->{order} || {}}) {
                $max_order = $v if $v > $max_order;
            }
            $cfg->{order}->{$id} = $max_order + 1;
            
            PVE::Network::SDN::Orchestrators::write_config($cfg);
        });

        return undef;
    }
});

__PACKAGE__->register_method({
    name => 'update',
    protected => 1,
    path => '{id}',
    method => 'PUT',
    description => "Update SDN orchestrator configuration.",
    permissions => {
        check => ['perm', '/sdn', ['SDN.Allocate']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            id => {
                type => 'string',
                format => 'pve-configid',
            },
            host => {
                type => 'string',
                format => 'address',
                optional => 1,
                description => "Host/IP address",
            },
            port => {
                type => 'integer',
                minimum => 1,
                maximum => 65535,
                optional => 1,
                description => "Port",
            },
            user => {
                type => 'string',
                optional => 1,
                description => "Username",
            },
            password => {
                type => 'string',
                optional => 1,
                description => "Password",
            },
            # AFC-specific parameters
            api_token => {
                type => 'string',
                optional => 1,
                description => "API token for AFC authentication",
            },
            fabric_name => {
                type => 'string',
                optional => 1,
                description => "AFC fabric name",
            },
            management_vlan => {
                type => 'integer',
                minimum => 1,
                maximum => 4094,
                optional => 1,
                description => "Management VLAN ID",
            },
            sync_mode => {
                type => 'string',
                enum => ['full', 'incremental'],
                optional => 1,
                description => "Synchronization mode",
            },
            # Common parameters
            enabled => {
                type => 'boolean',
                optional => 1,
                description => "Enable/disable",
            },
            verify_ssl => {
                type => 'boolean',
                optional => 1,
                description => "Verify SSL",
            },
            api_version => {
                type => 'string',
                optional => 1,
                description => "API version",
            },
            poll_interval_seconds => {
                type => 'integer',
                minimum => 10,
                maximum => 3600,
                optional => 1,
                description => "Polling interval in seconds",
            },
            request_timeout => {
                type => 'integer',
                minimum => 5,
                maximum => 300,
                optional => 1,
                description => "Request timeout in seconds",
            },
            reserved_vlans => {
                type => 'string',
                optional => 1,
                description => "Comma-separated list of reserved VLAN IDs",
            },
            reserved_vrf_names => {
                type => 'string',
                optional => 1,
                description => "Comma-separated list of reserved VRF names",
            },
            reserved_zone_names => {
                type => 'string',
                optional => 1,
                description => "Comma-separated list of reserved zone names",
            },
            description => {
                type => 'string',
                optional => 1,
                maxLength => 256,
                description => "Description",
            },
            delete => {
                type => 'string',
                format => 'pve-configid-list',
                optional => 1,
                description => "A list of settings to delete.",
            },
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        my $id = extract_param($param, 'id');
        my $delete = extract_param($param, 'delete');

        PVE::Network::SDN::Orchestrators::lock_config(sub {
            my $cfg = PVE::Network::SDN::Orchestrators::config();
            
            my $orch = PVE::Network::SDN::Orchestrators::sdn_orchestrators_config($cfg, $id);
            
            # Handle deletions
            if ($delete) {
                foreach my $key (PVE::Tools::split_list($delete)) {
                    delete $orch->{$key};
                }
            }
            
            # Update fields
            foreach my $key (keys %$param) {
                $orch->{$key} = $param->{$key};
            }
            
            PVE::Network::SDN::Orchestrators::write_config($cfg);
        });

        return undef;
    }
});

__PACKAGE__->register_method({
    name => 'delete',
    protected => 1,
    path => '{id}',
    method => 'DELETE',
    description => "Delete SDN orchestrator configuration.",
    permissions => {
        check => ['perm', '/sdn', ['SDN.Allocate']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            id => {
                type => 'string',
                format => 'pve-configid',
            },
        },
    },
    returns => { type => 'null' },
    code => sub {
        my ($param) = @_;

        my $id = $param->{id};

        PVE::Network::SDN::Orchestrators::lock_config(sub {
            my $cfg = PVE::Network::SDN::Orchestrators::config();
            
            die "orchestrator '$id' does not exist\n" if !$cfg->{ids}->{$id};
            
            delete $cfg->{ids}->{$id};
            delete $cfg->{order}->{$id} if $cfg->{order};
            
            PVE::Network::SDN::Orchestrators::write_config($cfg);
        });

        return undef;
    }
});

1;
