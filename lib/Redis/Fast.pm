package Redis::Fast;

BEGIN {
    use XSLoader;
    our $VERSION = '0.07';
    XSLoader::load __PACKAGE__, $VERSION;
}

use warnings;
use strict;

use Carp qw/confess/;
use Encode;
use Try::Tiny;
use Scalar::Util qw(weaken);

use Redis::Fast::Sentinel;

sub _new_on_connect_cb {
    my ($self, $on_conn, $password, $name) = @_;
    weaken $self;
    return sub {
        # If we are in PubSub mode we shouldn't perform any command besides
        # (p)(un)subscribe
        if (! $self->is_subscriber) {
            defined $name
                and try {
                    my $n = $name;
                    $n = $n->($self) if ref($n) eq 'CODE';
                    $self->client_setname($n) if defined $n;
                };
            my $data = $self->__get_data;
            defined $data->{current_database}
                and $self->select($data->{current_database});
        }

        my $subscribers = $self->__get_data->{subscribers};
        $self->__get_data->{subscribers} = {};
        $self->__get_data->{cbs} = undef;
        foreach my $topic (CORE::keys(%{$subscribers})) {
            if ($topic =~ /(p?message):(.*)$/ ) {
                my ($key, $channel) = ($1, $2);
                my $subs = $subscribers->{$topic};
                if ($key eq 'message') {
                    $self->__subscription_cmd('',  0, subscribe => $channel, $_) for @$subs;
                } else {
                    $self->__subscription_cmd('p',  0, psubscribe => $channel, $_) for @$subs;
                }
            }
        }

        defined $on_conn
            and $on_conn->($self);
    };
}

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
  $self->__set_on_connect($self->_new_on_connect_cb($on_conn, $password, $name));
  $self->__set_data({
      subscribers => {},
      sentinels_cnx_timeout    => $args{sentinels_cnx_timeout},
      sentinels_read_timeout   => $args{sentinels_read_timeout},
      sentinels_write_timeout  => $args{sentinels_write_timeout},
      no_sentinels_list_update => $args{no_sentinels_list_update},
  });

  if ($args{sock}) {
      $self->__connection_info_unix($args{sock});
  } elsif ($args{sentinels}) {
      my $sentinels = $args{sentinels};
      ref $sentinels eq 'ARRAY'
          or croak("'sentinels' param must be an ArrayRef");
      defined($self->__get_data->{service} = $args{service})
          or croak("Need 'service' name when using 'sentinels'!");
      $self->__get_data->{sentinels} = $sentinels;
      my $on_build_sock = sub {
          my $data = $self->__get_data;
          my $sentinels = $data->{sentinels};

          # try to connect to a sentinel
          my $status;
          foreach my $sentinel_address (@$sentinels) {
              my $sentinel = eval {
                  Redis::Fast::Sentinel->new(
                      server => $sentinel_address,
                      cnx_timeout   => (   exists $data->{sentinels_cnx_timeout}
                                               ? $data->{sentinels_cnx_timeout}   : 0.1),
                      read_timeout  => (   exists $data->{sentinels_read_timeout}
                                               ? $data->{sentinels_read_timeout}  : 1  ),
                      write_timeout => (   exists $data->{sentinels_write_timeout}
                                               ? $data->{sentinels_write_timeout} : 1  ),
                  )
              } or next;
              my $server_address = $sentinel->get_service_address($data->{service});
              defined $server_address
                or $status ||= "Sentinels don't know this service",
                   next;
              $server_address eq 'IDONTKNOW'
                and $status = "service is configured in one Sentinel, but was never reached",
                    next;

              # we found the service, set the server
              my ($server, $port) = split /:/, $server_address;
              $self->__connection_info($server, $port);

              if (! $data->{no_sentinels_list_update} ) {
                  # move the elected sentinel at the front of the list and add
                  # additional sentinels
                  my $idx = 2;
                  my %h = ( ( map { $_ => $idx++ } @{$data->{sentinels}}),
                            $sentinel_address => 1,
                          );
                  $data->{sentinels} = [
                      ( sort { $h{$a} <=> $h{$b} } keys %h ), # sorted existing sentinels,
                      grep { ! $h{$_}; }                      # list of unknown
                      map { +{ @$_ }->{name}; }               # names of
                      $sentinel->sentinel(                    # sentinels 
                        sentinels => $data->{service}         # for this service
                      )
                  ];
              }
          }
      };
      $self->__set_on_build_sock($on_build_sock);
  } else {
      my ($server, $port) = split /:/, ($args{server} || '127.0.0.1:6379');
      $self->__connection_info($server, $port);
  }

  #$self->{is_subscriber} = 0;
  #$self->{subscribers}   = {};
  $self->__set_reconnect($args{reconnect} || 0);
  $self->__set_every($args{every} || 1000);
  $self->__set_cnx_timeout($args{cnx_timeout} || -1);
  $self->__set_read_timeout($args{read_timeout} || -1);
  $self->__set_write_timeout($args{write_timeout} || -1);

  $self->connect unless $args{no_auto_connect_on_new};

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
    return unless $self->__sock;
    return scalar try {
        my ($ret, $error) = $self->__std_cmd('ping');
        return if defined $error;
        return $ret;
    } catch {
        return ;
    };
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

sub select {
  my $self = shift;
  my $database = shift;
  $self->__is_valid_command('select');
  my ($ret, $error) = $self->__std_cmd('SELECT', $database, @_);
  confess "[SELECT] $error, " if defined $error;
  $self->__get_data->{current_database} = $database;
  return $ret;
}

sub __subscription_cmd {
  my $self    = shift;
  my $pr      = shift;
  my $unsub   = shift;
  my $command = shift;
  my $cb      = pop;
  weaken $self;

  confess("Missing required callback in call to $command(), ")
    unless ref($cb) eq 'CODE';

  $self->wait_all_responses;

  while($self->__get_data->{cbs}) {
      $self->__wait_for_event(1);
  }

  my @subs = @_;
  @subs = $self->__process_unsubscribe_requests($cb, $pr, @subs)
      if $unsub;

  if(@subs) {
      $self->__get_data->{cbs} = { map { ("${pr}message:$_" => $cb) } @subs };
      for my $sub(@subs) {
          $self->__send_subscription_cmd(
              $command,
              $sub,
              $self->__subscription_callbak,
          );
      }
      while($self->__get_data->{cbs}) {
          $self->__wait_for_event(1);
      }
  }
}

sub __subscription_callbak {
    my $self = shift;
    my $cb = $self->__get_data->{callback};
    return $cb if $cb;

    weaken $self;
    $cb = sub {
        my $cbs = $self->__get_data->{cbs};
        if($cbs) {
            $self->__process_subscription_changes($cbs, @_);
            unless(%$cbs) {
                $self->__get_data->{cbs} = undef;
            }
        } else {
            $self->__process_pubsub_msg(@_);
        }
    };

    $self->__get_data->{callback} = $cb;
    return $cb;
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
  my ($self, $expected, $m, $error) = @_;
  my $subs = $self->__get_data->{subscribers};

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

=encoding utf-8

=head1 NAME

Redis::Fast - Perl binding for Redis database

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


=head1 PERFORMANCE IN SYNCHRONIZE MODE

=head2 Redis.pm

    Benchmark: running 00_ping, 10_set, 11_set_r, 20_get, 21_get_r, 30_incr, 30_incr_r, 40_lpush, 50_lpop, 90_h_get, 90_h_set for at least 5 CPU seconds...
       00_ping:  8 wallclock secs ( 0.69 usr +  4.77 sys =  5.46 CPU) @ 5538.64/s (n=30241)
        10_set:  8 wallclock secs ( 1.07 usr +  4.01 sys =  5.08 CPU) @ 5794.09/s (n=29434)
      11_set_r:  7 wallclock secs ( 0.42 usr +  4.84 sys =  5.26 CPU) @ 5051.33/s (n=26570)
        20_get:  8 wallclock secs ( 0.69 usr +  4.82 sys =  5.51 CPU) @ 5080.40/s (n=27993)
      21_get_r:  7 wallclock secs ( 2.21 usr +  3.09 sys =  5.30 CPU) @ 5389.06/s (n=28562)
       30_incr:  7 wallclock secs ( 0.69 usr +  4.73 sys =  5.42 CPU) @ 5671.77/s (n=30741)
     30_incr_r:  7 wallclock secs ( 0.85 usr +  4.31 sys =  5.16 CPU) @ 5824.42/s (n=30054)
      40_lpush:  8 wallclock secs ( 0.60 usr +  4.77 sys =  5.37 CPU) @ 5832.59/s (n=31321)
       50_lpop:  7 wallclock secs ( 1.24 usr +  4.17 sys =  5.41 CPU) @ 5112.75/s (n=27660)
      90_h_get:  7 wallclock secs ( 0.63 usr +  4.65 sys =  5.28 CPU) @ 5716.29/s (n=30182)
      90_h_set:  7 wallclock secs ( 0.65 usr +  4.74 sys =  5.39 CPU) @ 5593.14/s (n=30147)

=head2 Redis::Fast

Redis::Fast is 50% faster than Redis.pm.

    Benchmark: running 00_ping, 10_set, 11_set_r, 20_get, 21_get_r, 30_incr, 30_incr_r, 40_lpush, 50_lpop, 90_h_get, 90_h_set for at least 5 CPU seconds...
       00_ping:  9 wallclock secs ( 0.18 usr +  4.84 sys =  5.02 CPU) @ 7939.24/s (n=39855)
        10_set: 10 wallclock secs ( 0.31 usr +  5.40 sys =  5.71 CPU) @ 7454.64/s (n=42566)
      11_set_r:  9 wallclock secs ( 0.31 usr +  4.87 sys =  5.18 CPU) @ 7993.05/s (n=41404)
        20_get: 10 wallclock secs ( 0.27 usr +  4.84 sys =  5.11 CPU) @ 8350.68/s (n=42672)
      21_get_r: 10 wallclock secs ( 0.32 usr +  5.17 sys =  5.49 CPU) @ 8238.62/s (n=45230)
       30_incr:  9 wallclock secs ( 0.23 usr +  5.27 sys =  5.50 CPU) @ 8221.82/s (n=45220)
     30_incr_r:  8 wallclock secs ( 0.28 usr +  4.91 sys =  5.19 CPU) @ 8092.29/s (n=41999)
      40_lpush:  9 wallclock secs ( 0.18 usr +  5.06 sys =  5.24 CPU) @ 8312.02/s (n=43555)
       50_lpop:  9 wallclock secs ( 0.20 usr +  4.84 sys =  5.04 CPU) @ 8010.12/s (n=40371)
      90_h_get:  9 wallclock secs ( 0.19 usr +  5.51 sys =  5.70 CPU) @ 7467.72/s (n=42566)
      90_h_set:  8 wallclock secs ( 0.28 usr +  4.83 sys =  5.11 CPU) @ 7724.07/s (n=39470)o


=head1 PERFORMANCE IN PIPELINE MODE

    #!/usr/bin/perl
    use warnings;
    use strict;
    use Time::HiRes qw/time/;
    use Redis;
    
    my $count = 100000;
    {
        my $r = Redis->new;
        my $start = time;
        for(1..$count) {
            $r->set('hoge', 'fuga', sub{});
        }
        $r->wait_all_responses;
        printf "Redis.pm:\n%.2f/s\n", $count / (time - $start);
    }
    
    {
        my $r = Redis::Fast->new;
        my $start = time;
        for(1..$count) {
            $r->set('hoge', 'fuga', sub{});
        }
        $r->wait_all_responses;
        printf "Redis::Fast:\n%.2f/s\n", $count / (time - $start);
    }


Redis::Fast is 4x faster than Redis.pm in pipeline mode.

    Redis.pm:
    22588.95/s
    Redis::Fast:
    81098.01/s

=head1 AUTHOR

Ichinose Shogo E<lt>shogo82148@gmail.comE<gt>

=head1 SEE ALSO

=over 4

=item *

L<Redis.pm|https://github.com/melo/perl-redis>

=back

=cut
