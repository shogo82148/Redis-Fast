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

use constant SSL_AVAILABLE => eval { require IO::Socket::SSL };

my ($c, $t, $srv) = redis(timeout => 1);
my $use_ssl = $t ? SSL_AVAILABLE : 0;

END {
  $c->() if $c;
  $t->() if $t;
}

ok(my $r = Redis::Fast->new(reconnect => 1, server => $srv, no_auto_connect_on_new => 1, ssl => $use_ssl, SSL_verify_mode => 0), 'new without auto connect');
ok($r->set("foo", "bar"), "set works");

done_testing();
