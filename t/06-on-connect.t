#!perl

use warnings;
use strict;
use Test::More;
use Test::Fatal;
use Redis::Fast;
use lib 't/tlib';
use Test::SpawnRedisServer;

use constant SSL_AVAILABLE => eval { require IO::Socket::SSL };

my ($c, $t, $srv) = redis(timeout => 1);
my $use_ssl = $t ? SSL_AVAILABLE : 0;

END {
  $c->() if $c;
  $t->() if $t;
}

subtest 'on_connect' => sub {
  my $r;
  ok($r = Redis::Fast->new(server => $srv, on_connect => sub { shift->incr('on_connect') }, ssl => $use_ssl, SSL_verify_mode => 0),
    'connected to our test redis-server');
  is($r->get('on_connect'), 1, '... on_connect code was run');

  ok($r = Redis::Fast->new(server => $srv, on_connect => sub { shift->incr('on_connect') }, ssl => $use_ssl, SSL_verify_mode => 0),
    'new connection is up and running');
  is($r->get('on_connect'), 2, '... on_connect code was run again');

  ok($r = Redis::Fast->new(reconnect => 1, server => $srv, on_connect => sub { shift->incr('on_connect') }, ssl => $use_ssl, SSL_verify_mode => 0),
    'new connection with reconnect enabled');
  is($r->get('on_connect'), 3, '... on_connect code one again perfect');

  $r->quit;
  is($r->get('on_connect'), 4, '... on_connect code works after reconnect also');
};


done_testing();
