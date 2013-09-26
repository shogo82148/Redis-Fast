package Redis::Fast::List;

# ABSTRACT: tie Perl arrays to Redis lists
# VERSION
# AUTHORITY

use strict;
use warnings;
use base qw/Redis::Fast Tie::Array/;


sub TIEARRAY {
  my ($class, $list, @rest) = @_;
  my $self = $class->new(@rest);

  $self->__set_data($list);

  return $self;
}

sub FETCH {
  my ($self, $index) = @_;
  $self->lindex($self->__get_data, $index);
}

sub FETCHSIZE {
  my ($self) = @_;
  $self->llen($self->__get_data);
}

sub STORE {
  my ($self, $index, $value) = @_;
  $self->lset($self->__get_data, $index, $value);
}

sub STORESIZE {
  my ($self, $count) = @_;
  $self->ltrim($self->__get_data, 0, $count);

#		if $count > $self->FETCHSIZE;
}

sub CLEAR {
  my ($self) = @_;
  $self->del($self->__get_data);
}

sub PUSH {
  my $self = shift;
  my $list = $self->__get_data;

  $self->rpush($list, $_) for @_;
}

sub POP {
  my $self = shift;
  $self->rpop($self->__get_data);
}

sub SHIFT {
  my ($self) = @_;
  $self->lpop($self->__get_data);
}

sub UNSHIFT {
  my $self = shift;
  my $list = $self->__get_data;

  $self->lpush($list, $_) for @_;
}

sub SPLICE {
  my ($self, $offset, $length) = @_;
  $self->lrange($self->__get_data, $offset, $length);

  # FIXME rest of @_ ?
}

sub EXTEND {
  my ($self, $count) = @_;
  $self->rpush($self->__get_data, '') for ($self->FETCHSIZE .. ($count - 1));
}

sub DESTROY { $_[0]->quit }

1;    ## End of Redis::List

=head1 SYNOPSYS

    tie @my_list, 'Redis::List', 'list_name', @Redis_new_parameters;

    $value = $my_list[$index];
    $my_list[$index] = $value;

    $count = @my_list;

    push @my_list, 'values';
    $value = pop @my_list;
    unshift @my_list, 'values';
    $value = shift @my_list;

    ## NOTE: fourth parameter of splice is *NOT* supported for now
    @other_list = splice(@my_list, 2, 3);

    @my_list = ();


=cut
