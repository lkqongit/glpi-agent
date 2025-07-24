package GLPI::Agent::SNMP::MibSupport::Juniper;

use strict;
use warnings;

use parent 'GLPI::Agent::SNMP::MibSupportTemplate';

use GLPI::Agent::Tools;
use GLPI::Agent::Tools::SNMP;

use constant    enterprises => '.1.3.6.1.4.1' ;

# See JUNIPER-SMI
use constant    juniperMIB      => enterprises . '.2636';
use constant    jnxMIBs         => juniperMIB . '.3';
use constant    jnxExMibRoot    => jnxMIBs . '.40';

# See JUNIPER-EX-SMI
use constant    jnxExVirtualChassis => jnxExMibRoot . '.1.4';

# See JUNIPER-VIRTUALCHASSIS-MIB
use constant    jnxVirtualChassisMemberSerialnumber => jnxExVirtualChassis . '.1.1.1.2.0';
use constant    jnxVirtualChassisMemberMacAddBase   => jnxExVirtualChassis . '.1.1.1.4.0';
use constant    jnxVirtualChassisMemberSWVersion    => jnxExVirtualChassis . '.1.1.1.5.0';
use constant    jnxVirtualChassisMemberModel        => jnxExVirtualChassis . '.1.1.1.8.0';


our $mibSupport = [
    {
        name        => "juniper",
        sysobjectid => getRegexpOidMatch(juniperMIB)
    }
];

sub getFirmware {
    my ($self) = @_;

    return getCanonicalString($self->get(jnxVirtualChassisMemberSWVersion));
}

sub getMacAddress {
    my ($self) = @_;

    return getCanonicalMacAddress($self->get(jnxVirtualChassisMemberMacAddBase));
}

sub getModel {
    my ($self) = @_;

    return getCanonicalString($self->get(jnxVirtualChassisMemberModel));
}

sub getSerial {
    my ($self) = @_;

    my $device = $self->device
        or return;

    return if $device->{SERIAL};

    return getCanonicalString($self->get(jnxVirtualChassisMemberSerialnumber));
}

sub run {
    my ($self) = @_;

    my $device = $self->device
        or return;

    if ($device->{PORTS} && ref($device->{PORTS}->{PORT}) eq 'HASH') {

        # Index ports by IFNAME
        my %ports;
        my %index;
        my $ports = $device->{PORTS}->{PORT};
        my @portnames = sortedPorts($ports);
        foreach my $index (@portnames) {
            next if empty($ports->{$index}->{IFNAME});
            $index{$ports->{$index}->{IFNAME}} = $index;
            $ports{$ports->{$index}->{IFNAME}} = $ports->{$index};
        }

        # Search virtualport on which physical port should be merged to handle
        # connections as expected in GLPI
        foreach my $name (@portnames) {
            my $port = $ports{$name};
            next unless $port->{IFTYPE} && isInteger($port->{IFTYPE}) && int($port->{IFTYPE}) == 53;
            my ($physical) = $name =~ /^(.+)\.\d+$/
                or next;
            next unless $ports{$physical};
            next unless $port->{MAC} && $ports->{$index{$physical}}->{MAC} && $port->{MAC} eq $ports->{$index{$physical}}->{MAC};
            next unless $port->{IFMTU} && $ports->{$index{$physical}}->{IFMTU} && $port->{IFMTU} eq $ports->{$index{$physical}}->{IFMTU};
            my $merge = delete $ports->{$index{$physical}};
            map {
                $port->{$_} = $merge->{$_} if $merge->{$_}
            } qw( IFNAME IFDESCR IFTYPE IFSPEED VLAN);
            map {
                $port->{$_} = 0 unless $port->{$_};
                $port->{$_} += $merge->{$_} if $merge->{$_};
            } qw( IFINERRORS IFINOCTETS IFOUTERRORS IFOUTOCTETS );
        }
    }
}

1;

__END__

=head1 NAME

GLPI::Agent::SNMP::MibSupport::Juniper - Inventory module to fix Juniper connections

=head1 DESCRIPTION

The module enhances Juniper support.
