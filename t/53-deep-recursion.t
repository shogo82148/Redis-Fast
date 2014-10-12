#!perl

use warnings;
use strict;
use Test::More;
use Test::Fatal;
use Redis::Fast;
use lib 't/tlib';
use Test::SpawnRedisServer;

my ($c, $srv) = redis(
    maxclients => 1,
);
END { $c->() if $c }

ok my $r1 = Redis::Fast->new(
    server => $srv,
    name          => 'my-first-connection',
    reconnect     => 20,
    every         => 1000,
    on_connect => sub {
        my ( $redis ) = @_;
        $redis->select(1);
    },
), "first connection is success";

like(
  exception {
      my $r2 = Redis::Fast->new(
          server => $srv,
          name          => 'my-second-connection',
          reconnect     => 20,
          every         => 1000,
          on_connect => sub {
              my ( $redis ) = @_;
              $redis->select(1);
          },
      );
  },
  qr/ERR max number of clients reached/, 'second connection is fail',
);

## All done
done_testing();
