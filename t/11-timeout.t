#!perl

use strict;
use warnings;
use Test::More;
use Test::Fatal;
use Redis::Fast;
use lib 't/tlib';
use Test::SpawnRedisTimeoutServer;
use Errno qw(ETIMEDOUT EWOULDBLOCK);
use POSIX qw(strerror);
use Carp;
use IO::Socket::INET;
use Test::TCP;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

subtest 'server replies quickly enough' => sub {
    my $server = Test::SpawnRedisTimeoutServer::create_server_with_timeout(0);
    my $redis = Redis::Fast->new(server => '127.0.0.1:' . $server->port, read_timeout => 1);
    ok($redis);
    my $res = $redis->get('foo');;
    is $res, 42;
};

subtest "server doesn't replies quickly enough" => sub {
    my $server = Test::SpawnRedisTimeoutServer::create_server_with_timeout(10);
    my $redis = Redis::Fast->new(server => '127.0.0.1:' . $server->port, read_timeout => 1);
    ok($redis);
    like(
         exception { $redis->get('foo'); },
         qr/Error while reading from Redis server: /,
         "the code died as expected",
        );
    ok($! == ETIMEDOUT || $! == EWOULDBLOCK);
};

done_testing;
