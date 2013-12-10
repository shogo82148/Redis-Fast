# NAME

Redis::Fast - Perl binding for Redis database

# SYNOPSIS

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



# DESCRIPTION

`Redis::Fast` is a wrapper around Salvatore Sanfilippo's
[hiredis](https://github.com/antirez/hiredis) C client.
It is compatible with [Redis.pm](https://github.com/melo/perl-redis).

This version supports protocol 2.x (multi-bulk) or later of Redis available at
[https://github.com/antirez/redis/](https://github.com/antirez/redis/).



# PERFORMANCE IN SYNCHRONIZE MODE

## Redis.pm

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

## Redis::Fast

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



# PERFORMANCE IN PIPELINE MODE

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

# AUTHOR

Ichinose Shogo <shogo82148@gmail.com>

# SEE ALSO

- [Redis.pm](https://github.com/melo/perl-redis)
