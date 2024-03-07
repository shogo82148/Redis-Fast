#!perl
# Test for fixing https://github.com/shogo82148/Redis-Fast/issues/117

use warnings;
use strict;
use Test::More;
use Test::Fatal;
use Redis::Fast;
use lib 't/tlib';
use Test::SpawnRedisServer;
use Test::Deep;

use constant SSL_AVAILABLE => eval { require IO::Socket::SSL };

my ($c, $t, $srv) = redis();
my $use_ssl = $t ? SSL_AVAILABLE : 0;

END {
  $c->() if $c;
  $t->() if $t;
}

{
my $r = Redis::Fast->new(server => $srv, ssl => $use_ssl, SSL_verify_mode => 0);
eval { $r->multi( ); };
plan 'skip_all' => "multi without arguments not implemented on this redis server"  if $@ && $@ =~ /unknown command/;
}


ok(my $r = Redis::Fast->new(server => $srv, reconnect => 1, ssl => $use_ssl, SSL_verify_mode => 0), 'connected to our test redis-server');
my $r2 = Redis::Fast->new(server => $srv, ssl => $use_ssl, SSL_verify_mode => 0);

my $is_called = 0;
my $test_key = "RedisTestKey";

$r->set( $test_key => 'MyValue' );

$r->get( $test_key, sub { } );
$r2->shutdown;
$r->get( $test_key, sub { $is_called = 1; diag $_[0], $_[1] } );

eval {
    # it sometimes fails with "Connection reset by peer", but it's OK.
    $r->wait_all_responses;
};

ok $is_called, "callback is called";

done_testing();
