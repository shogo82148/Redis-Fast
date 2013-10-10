package Redis::Fast;

# ABSTRACT: Perl binding for Redis database
BEGIN {
    use XSLoader;
    our $VERSION = '0.01';
    XSLoader::load __PACKAGE__, $VERSION;
}

use warnings;
use strict;

use Data::Dumper;
use Carp qw/confess/;
use Encode;
use Try::Tiny;


sub new {
  my $class = shift;
  my %args  = @_;
  my $self  = $class->_new;

  #$self->{debug} = $args{debug} || $ENV{REDIS_DEBUG};

  ## default to lax utf8
  my $encoding = exists $args{encoding} ? $args{encoding} : 'utf8';
  if(!$encoding) {
    $self->__set_utf8(0);
  } elsif($encoding eq 'utf8') {
    $self->__set_utf8(1);
  } else {
    die "encoding $encoding does not support";
  }

  ## Deal with REDIS_SERVER ENV
  if ($ENV{REDIS_SERVER} && !$args{sock} && !$args{server}) {
    if ($ENV{REDIS_SERVER} =~ m!^/!) {
      $args{sock} = $ENV{REDIS_SERVER};
    }
    elsif ($ENV{REDIS_SERVER} =~ m!^unix:(.+)!) {
      $args{sock} = $1;
    }
    elsif ($ENV{REDIS_SERVER} =~ m!^(tcp:)?(.+)!) {
      $args{server} = $2;
    }
  }

  my $on_conn = $args{on_connect};
  my $password = $args{password};
  my $name = $args{name};
  $self->__set_on_connect(
      sub {
          try {
              $self->auth($password) if defined $password;
          } catch {
              confess("Redis server refused password");
          };
          try {
              my $n = $name;
              $n = $n->($self) if ref($n) eq 'CODE';
              $self->client_setname($n) if defined $n;
          };
          $on_conn->($self) if $on_conn;
      }
  );
  $self->__set_data({
      subscribers => {},
  });

  if ($args{sock}) {
    $self->__connection_info_unix($args{sock});
  }
  else {
    my ($server, $port) = split /:/, ($args{server} || '127.0.0.1:6379');
    $self->__connection_info($server, $port);
  }

  #$self->{is_subscriber} = 0;
  #$self->{subscribers}   = {};
  $self->__set_reconnect($args{reconnect} || 0);
  $self->__set_every($args{every} || 1000);

  $self->__connect;

  return $self;
}


### Deal with common, general case, Redis commands
our $AUTOLOAD;

sub AUTOLOAD {
  my $command = $AUTOLOAD;
  $command =~ s/.*://;
  my @command = split /_/, uc $command;

  my $method = sub {
      my $self = shift;
      $self->__is_valid_command($command);
      my ($ret, $error) = $self->__std_cmd(@command, @_);
      confess "[$command] $error, " if defined $error;
      return (wantarray && ref $ret eq 'ARRAY') ? @$ret : $ret;
  };

  # Save this method for future calls
  no strict 'refs';
  *$AUTOLOAD = $method;

  goto $method;
}

sub __with_reconnect {
  my ($self, $cb) = @_;

  confess "not implemented";
}


### Commands with extra logic

sub keys {
    my $self = shift;
    $self->__is_valid_command('keys');
    my ($ret, $error) = $self->__keys(@_);
    confess "[keys] $error, " if defined $error;
    return $ret unless ref $ret eq 'ARRAY';
    return @$ret;
}

sub ping {
    my $self = shift;
    $self->__is_valid_command('ping');
    my ($ret, $error) = $self->__ping;
    confess "[keys] $error, " if defined $error;
    return $ret unless ref $ret eq 'ARRAY';
    return @$ret;
}

sub info {
    my $self = shift;
    $self->__is_valid_command('info');
    my ($ret, $error) = $self->__info(@_);
    confess "[keys] $error, " if defined $error;
    return $ret unless ref $ret eq 'ARRAY';
    return @$ret;
}

sub quit {
    my $self = shift;
    $self->__is_valid_command('quit');
    $self->__quit(@_);
}

sub shutdown {
    my $self = shift;
    $self->__is_valid_command('shutdown');
    $self->__shutdown(@_);
}

sub __subscription_cmd {
  my $self    = shift;
  my $pr      = shift;
  my $unsub   = shift;
  my $command = shift;
  my $cb      = pop;

  confess("Missing required callback in call to $command(), ")
    unless ref($cb) eq 'CODE';

  $self->wait_all_responses;

  my @subs = @_;
  @subs = $self->__process_unsubscribe_requests($cb, $pr, @subs)
      if $unsub;
  my %cbs = map { ("${pr}message:$_" => $cb) } @subs;
  if(@subs) {
      return $self->__send_subscription_cmd(
          $command,
          @subs,
          sub {
              return $self->__process_subscription_changes($command, \%cbs, @_);
          },
      );
  } else {
      return 0;
  }
}

sub subscribe    { shift->__subscription_cmd('',  0, subscribe    => @_) }
sub psubscribe   { shift->__subscription_cmd('p', 0, psubscribe   => @_) }
sub unsubscribe  { shift->__subscription_cmd('',  1, unsubscribe  => @_) }
sub punsubscribe { shift->__subscription_cmd('p', 1, punsubscribe => @_) }

sub __process_unsubscribe_requests {
  my ($self, $cb, $pr, @unsubs) = @_;
  my $subs = $self->__get_data->{subscribers};

  my @subs_to_unsubscribe;
  for my $sub (@unsubs) {
    my $key = "${pr}message:$sub";
    next unless $subs->{$key} && @{ $subs->{$key} };
    my $cbs = $subs->{$key} = [grep { $_ ne $cb } @{ $subs->{$key} }];
    next if @$cbs;

    delete $subs->{$key};
    push @subs_to_unsubscribe, $sub;
  }
  return @subs_to_unsubscribe;
}

sub __process_subscription_changes {
  my ($self, $cmd, $expected, $m, $error) = @_;
  my $subs = $self->__get_data->{subscribers};

  confess "[$cmd] $error, " if defined $error;

  ## Deal with pending PUBLISH'ed messages
  if ($m->[0] =~ /^p?message$/) {
    $self->__process_pubsub_msg($m);
    return ;
  }

  my ($key, $unsub) = $m->[0] =~ m/^(p)?(un)?subscribe$/;
  $key .= "message:$m->[1]";
  my $cb = delete $expected->{$key};

  push @{ $subs->{$key} }, $cb unless $unsub;
}

sub __process_pubsub_msg {
  my ($self, $m) = @_;
  my $subs = $self->__get_data->{subscribers};

  my $sub   = $m->[1];
  my $cbid  = "$m->[0]:$sub";
  my $data  = pop @$m;
  my $topic = $m->[2] || $sub;

  if (!exists $subs->{$cbid}) {
    warn "Message for topic '$topic' ($cbid) without expected callback, ";
    return 0;
  }

  $_->($data, $topic, $sub) for @{ $subs->{$cbid} };

  return 1;

}

sub __is_valid_command {
  my ($self, $cmd) = @_;

  confess("Cannot use command '$cmd' while in SUBSCRIBE mode, ")
    if $self->is_subscriber;
}

1;    # End of Redis.pm

__END__

=head1 AUTHOR

Ichinose Shogo E<lt>shogo82148@gmail.comE<gt>

=head1 SYNOPSIS

    ## Defaults to $ENV{REDIS_SERVER} or 127.0.0.1:6379
    my $redis = Redis::Fast->new;

    my $redis = Redis::Fast->new(server => 'redis.example.com:8080');

    ## Set the connection name (requires Redis 2.6.9)
    my $redis = Redis::Fast->new(
      server => 'redis.example.com:8080',
      name => 'my_connection_name',
    );
    my $generation = 0;
    my $redis = Redis::Fast->new(
      server => 'redis.example.com:8080',
      name => sub { "cache-$$-".++$generation },
    );

    ## Use UNIX domain socket
    my $redis = Redis::Fast->new(sock => '/path/to/socket');

    ## Enable auto-reconnect
    ## Try to reconnect every 500ms up to 60 seconds until success
    ## Die if you can't after that
    my $redis = Redis::Fast->new(reconnect => 60);

    ## Try each 100ms upto 2 seconds (every is in milisecs)
    my $redis = Redis::Fast->new(reconnect => 2, every => 100);

    ## Disable the automatic utf8 encoding => much more performance
    ## !!!! This will be the default after 2.000, see ENCODING below
    my $redis = Redis::Fast->new(encoding => undef);

    ## Use all the regular Redis commands, they all accept a list of
    ## arguments
    ## See http://redis.io/commands for full list
    $redis->get('key');
    $redis->set('key' => 'value');
    $redis->sort('list', 'DESC');
    $redis->sort(qw{list LIMIT 0 5 ALPHA DESC});

    ## Add a coderef argument to run a command in the background
    $redis->sort(qw{list LIMIT 0 5 ALPHA DESC}, sub {
      my ($reply, $error) = @_;
      die "Oops, got an error: $error\n" if defined $error;
      print "$_\n" for @$reply;
    });
    long_computation();
    $redis->wait_all_responses;
    ## or
    $redis->wait_one_response();

    ## Or run a large batch of commands in a pipeline
    my %hash = _get_large_batch_of_commands();
    $redis->hset('h', $_, $hash{$_}, sub {}) for keys %hash;
    $redis->wait_all_responses;

    ## Publish/Subscribe
    $redis->subscribe(
      'topic_1',
      'topic_2',
      sub {
        my ($message, $topic, $subscribed_topic) = @_

          ## $subscribed_topic can be different from topic if
          ## you use psubscribe() with wildcards
      }
    );
    $redis->psubscribe('nasdaq.*', sub {...});

    ## Blocks and waits for messages, calls subscribe() callbacks
    ##  ... forever
    my $timeout = 10;
    $redis->wait_for_messages($timeout) while 1;

    ##  ... until some condition
    my $keep_going = 1; ## other code will set to false to quit
    $redis->wait_for_messages($timeout) while $keep_going;

    $redis->publish('topic_1', 'message');


=head1 DESCRIPTION

C<Redis::Fast> is a wrapper around Salvatore Sanfilippo's
L<hiredis|https://github.com/antirez/hiredis> C client.
It is compatible with L<Redis.pm|https://github.com/melo/perl-redis>.

This version supports protocol 2.x (multi-bulk) or later of Redis available at
L<https://github.com/antirez/redis/>.


=head1 SEE ALSO

=over 4

=item *

L<Redis.pm|https://github.com/melo/perl-redis>

=back

=cut
