#!perl

use warnings;
use strict;
use Test::More;
use Test::Fatal;
use Redis::Fast;
use lib 't/tlib';
use Test::SpawnRedisServer;

use constant SSL_AVAILABLE => eval { require IO::Socket::SSL };

my ($c, $t, $srv) = redis(maxclients => 1);
my $use_ssl = $t ? SSL_AVAILABLE : 0;

END {
  $c->() if $c;
  $t->() if $t;
}

ok my $r1 = Redis::Fast->new(
    server => $srv,
    name          => 'my-first-connection',
    reconnect     => 1,
    every         => 1000,
    on_connect => sub {
        my ( $redis ) = @_;
        $redis->select(1);
    },
    ssl => $use_ssl,
    SSL_verify_mode => 0,
), "first connection is success";

like(
  exception {
      my $r2 = Redis::Fast->new(
          server => $srv,
          name          => 'my-second-connection',
          reconnect     => 1,
          every         => 1000,
          on_connect => sub {
              my ( $redis ) = @_;
              $redis->select(1);
          },
        ssl => $use_ssl,
        SSL_verify_mode => 0,
      );
  },
  qr/Could not connect to Redis server at/, 'second connection is fail',
);

## All done
done_testing();
