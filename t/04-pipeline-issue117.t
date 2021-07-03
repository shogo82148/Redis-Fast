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

my ($c, $srv) = redis();
END { $c->() if $c }
{
my $r = Redis::Fast->new(server => $srv);
eval { $r->multi( ); };
plan 'skip_all' => "multi without arguments not implemented on this redis server"  if $@ && $@ =~ /unknown command/;
}


ok(my $r = Redis::Fast->new(server => $srv, reconnect => 1), 'connected to our test redis-server');
my $r2 = Redis::Fast->new(server => $srv);

my $is_called = 0;
my $test_key = "RedisTestKey";

$r->set( $test_key => 'MyValue' );

$r->get( $test_key, sub { } );
$r2->shutdown;
$r->get( $test_key, sub { $is_called = 1; diag $_[0], $_[1] } );

$r->wait_all_responses;

ok $is_called, "callback is called";

done_testing();
