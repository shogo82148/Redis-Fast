#!perl

use warnings;
use strict;
use Test::More;
use Test::Fatal;
use Time::HiRes qw(gettimeofday tv_interval);
use Redis::Fast;
use lib 't/tlib';
use Test::SpawnRedisServer;
use Net::EmptyPort qw(empty_port);

my ($c, $srv) = redis(timeout => 1);
END { $c->() if $c }

ok(my $r = Redis::Fast->new(reconnect => 1, server => $srv, no_auto_connect_on_new => 1), 'new without auto connect');
ok($r->ping, "ping works");

done_testing();
