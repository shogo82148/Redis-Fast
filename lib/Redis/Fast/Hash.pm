package Redis::Fast::Hash;

# ABSTRACT: tie Perl hashes to Redis hashes
# VERSION
# AUTHORITY

use strict;
use warnings;
use Tie::Hash;
use base qw/Redis::Fast Tie::StdHash/;


sub TIEHASH {
  my ($class, $prefix, @rest) = @_;
  my $self = $class->new(@rest);

  $self->__set_data({});
  $self->__get_data->{prefix} = $prefix ? "$prefix:" : '';

  return $self;
}

sub STORE {
  my ($self, $key, $value) = @_;
  $self->set($self->__get_data->{prefix} . $key, $value);
}

sub FETCH {
  my ($self, $key) = @_;
  $self->get($self->__get_data->{prefix} . $key);
}

sub FIRSTKEY {
  my $self = shift;
  $self->__get_data->{prefix_keys} = [$self->keys($self->__get_data->{prefix} . '*')];
  $self->NEXTKEY;
}

sub NEXTKEY {
  my $self = shift;

  my $key = shift @{ $self->__get_data->{prefix_keys} };
  return unless defined $key;

  my $p = $self->__get_data->{prefix};
  $key =~ s/^$p// if $p;
  return $key;
}

sub EXISTS {
  my ($self, $key) = @_;
  $self->exists($self->__get_data->{prefix} . $key);
}

sub DELETE {
  my ($self, $key) = @_;
  $self->del($self->__get_data->{prefix} . $key);
}

sub CLEAR {
  my ($self) = @_;
  $self->del($_) for $self->keys($self->__get_data->{prefix} . '*');
  $self->__get_data->{prefix_keys} = [];
}


1;    ## End of Redis::Hash


=head1 SYNOPSYS

    ## Create fake hash using keys like 'hash_prefix:KEY'
    tie %my_hash, 'Redis::Hash', 'hash_prefix', @Redis_new_parameters;

    ## Treat the entire Redis database as a hash
    tie %my_hash, 'Redis::Hash', undef, @Redis_new_parameters;

    $value = $my_hash{$key};
    $my_hash{$key} = $value;

    @keys   = keys %my_hash;
    @values = values %my_hash;

    %my_hash = reverse %my_hash;

    %my_hash = ();


=head1 DESCRIPTION

Ties a Perl hash to Redis. Note that it doesn't use Redis Hashes, but
implements a fake hash using regular keys like "prefix:KEY".

If no C<prefix> is given, it will tie the entire Redis database as a hash.

Future versions will also allow you to use real Redis hash structures.

=cut
