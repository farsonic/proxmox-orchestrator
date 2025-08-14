package PVE::Network::SDN::Orchestrators;

# File: /usr/share/perl5/PVE/Network/SDN/Orchestrators.pm
# Working manual parser version

use strict;
use warnings;

use PVE::Tools;
use Digest::SHA;
use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);

my $config_file = "sdn/orchestrators.cfg";
#my $config_file = "sdn/psm-hosts.cfg";

# Manual parser
sub parse_orchestrators_config {
    my ($filename, $raw) = @_;
    
    my $cfg = { ids => {}, order => {}, digest => '' };
    
    return $cfg unless $raw;
    
    # Calculate digest
    $cfg->{digest} = Digest::SHA::sha1_hex($raw);
    
    my $current_section;
    my $section_num = 1;
    
    foreach my $line (split(/\n/, $raw)) {
        next if $line =~ /^\s*$/;  # skip empty
        next if $line =~ /^\s*#/;   # skip comments
        
        if ($line =~ /^(\S+):\s*(\S+)$/) {
            # New section
            my ($type, $id) = ($1, $2);
            $current_section = $id;
            $cfg->{ids}->{$id} = {
                type => $type,
            };
            $cfg->{order}->{$id} = $section_num++;
        }
        elsif ($line =~ /^\s+(\S+)\s+(.*)$/ && $current_section) {
            # Property in section
            my ($key, $value) = ($1, $2);
            
            # Convert booleans
            if ($value eq '1' || $value eq 'true') {
                $value = 1;
            } elsif ($value eq '0' || $value eq 'false') {
                $value = 0;
            }
            
            $cfg->{ids}->{$current_section}->{$key} = $value;
        }
    }
    
    return $cfg;
}

# Manual writer
sub write_orchestrators_config {
    my ($filename, $cfg) = @_;
    
    my $output = "";
    
    # Sort by order if available, otherwise by ID
    my @ids;
    if ($cfg->{order}) {
        @ids = sort { ($cfg->{order}->{$a} || 999) <=> ($cfg->{order}->{$b} || 999) } keys %{$cfg->{ids}};
    } else {
        @ids = sort keys %{$cfg->{ids}};
    }
    
    foreach my $id (@ids) {
        my $section = $cfg->{ids}->{$id};
        my $type = $section->{type} || 'psm';
        
        $output .= "$type: $id\n";
        
        foreach my $key (sort keys %$section) {
            next if $key eq 'type';
            
            my $value = $section->{$key};
            
            # Convert booleans for output
            if ($key eq 'enabled' || $key eq 'verify_ssl') {
                $value = $value ? '1' : '0';
            }
            
            $output .= "\t$key $value\n" if defined $value;
        }
    }
    
    return $output;
}

# Register with cluster file system
PVE::Cluster::cfs_register_file($config_file,
    sub { 
        my ($filename, $raw) = @_;
        return parse_orchestrators_config($filename, $raw);
    },
    sub {
        my ($filename, $cfg) = @_;
        return write_orchestrators_config($filename, $cfg);
    });

# Public API functions
sub config {
    # Always use direct parsing for now
    my $path = "/etc/pve/sdn/orchestrators.cfg";
    
    if (-f $path) {
        my $raw = PVE::Tools::file_get_contents($path);
        return parse_orchestrators_config($path, $raw);
    }
    
    return { ids => {}, order => {}, digest => '' };
}

sub write_config {
    my ($cfg) = @_;
    
    my $path = "/etc/pve/sdn/orchestrators.cfg";
    my $content = write_orchestrators_config($path, $cfg);
    PVE::Tools::file_set_contents($path, $content);
}

sub lock_config {
    my ($code, $errmsg) = @_;
    
    my $lockfile = "/var/lock/orchestrators.lock";
    
    eval {
        PVE::Tools::lock_file($lockfile, 10, $code);
    };
    
    if ($@) {
        die "$errmsg: $@\n" if $errmsg;
        die $@;
    }
}

sub sdn_orchestrators_config {
    my ($cfg, $id, $noerr) = @_;
    
    die "no orchestrator ID specified\n" if !$id;
    
    my $scfg = $cfg->{ids}->{$id};
    die "orchestrator '$id' does not exist\n" if (!$noerr && !$scfg);
    
    return $scfg;
}

sub sdn_orchestrators_ids {
    my ($cfg) = @_;
    return [sort keys %{$cfg->{ids}}];
}

# Compatibility functions
sub config_digest {
    my ($cfg) = @_;
    return $cfg->{digest} || 'simple';
}

sub assert_if_modified {
    my ($cfg, $digest) = @_;
    return;  # Skip digest checking for now
}

sub set_password {
    my ($password) = @_;
    return $password;
}

sub delete_password {
    my ($password_key) = @_;
    return;
}

1;
