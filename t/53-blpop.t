use strict;
use warnings;
use Test::More;
use Redis::Fast;
use lib 't/tlib';
use Test::SpawnRedisServer;

use constant SSL_AVAILABLE => eval { require IO::Socket::SSL };

my ( $c, $t, $srv ) = redis();
my $use_ssl = $t ? SSL_AVAILABLE : 0;

END {
    $c->() if $c;
    $t->() if $t;
}

my $redis = Redis::Fast->new(
    server          => $srv,
    name            => 'blpop_test',
    reconnect       => 1,
    cnx_timeout     => 0.2,
    read_timeout    => 1,
    ssl             => $use_ssl,
    SSL_verify_mode => 0,
);

unless ( fork() ) {
    # it will exit with read timeout
    eval { $redis->blpop( "somekey", 3 ); };
    exit;
}

sleep 2;
$redis->rpush( "somekey", 4 );
sleep 1;
is $redis->lpop("somekey"), 4, 'blpop is time out while lpop is success';

wait;

done_testing;
