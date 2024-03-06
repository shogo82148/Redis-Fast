package Redis::Fast::Sentinel;

# ABSTRACT: Redis::Fast Sentinel interface

use warnings;
use strict;

use Carp;

use base qw(Redis::Fast);

sub new {
    my ($class, %args) = @_;
    # these args are not allowed when contacting a sentinel
    delete @args{qw(sentinels service)};
    # Do not support SSL for sentinels
    $args{ssl} = 0;

    $class->SUPER::new(%args);
}

sub get_service_address {
    my ($self, $service) = @_;
    my ($ip, $port) = $self->sentinel('get-master-addr-by-name', $service);
    defined $ip
      or return;
    $ip eq 'IDONTKNOW'
      and return $ip;
    return "$ip:$port";
}

sub get_masters {
    map { +{ @$_ }; } @{ shift->sentinel('masters') || [] };
}

1;

__END__
=head1 NAME

    Redis::Fast::Sentinel - connect to a Sentinel instance

=head1 SYNOPSIS

    my $sentinel = Redis::Fast::Sentinel->new( ... );
    my $service_address = $sentinel->get_service_address('mymaster');
    my @masters = $sentinel->get_masters;

=head1 DESCRIPTION

This is a subclass of the Redis::Fast module, specialized into connecting to a
Sentinel instance. Inherits from the C<Redis::Fast> package;

=head1 CONSTRUCTOR

=head2 new

See C<new> in L<Redis::Fast>. All parameters are supported, except C<sentinels>
and C<service>, which are silently ignored.

=head1 METHODS

All the methods of the C<Redis::Fast> package are supported, plus the additional following methods:

=head2 get_service_address

Takes the name of a service as parameter, and returns either void (empty list)
if the master couldn't be found, the string 'IDONTKNOW' if the service is in
the sentinel config but cannot be reached, or the string C<"$ip:$port"> if the
service were found.

=head2 get_masters

Returns a list of HashRefs representing all the master redis instances that
this sentinel monitors.

=cut
