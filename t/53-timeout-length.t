use strict;
use warnings;
use Test::More;
use Test::Fatal;
use Redis::Fast;
use lib 't/tlib';
use Test::SpawnRedisServer;
use Time::HiRes qw/gettimeofday tv_interval/;

use constant SSL_AVAILABLE => eval { require IO::Socket::SSL };

my ( $c, $t, $srv ) = redis();
my $use_ssl = $t ? SSL_AVAILABLE : 0;

END {
    $c->() if $c;
    $t->() if $t;
}

my $redis = Redis::Fast->new(
    server          => $srv,
    name            => 'my_name_is_glorious',
    reconnect       => 1,
    write_timeout   => 1,
    ssl             => $use_ssl,
    SSL_verify_mode => 0,
);

my $start_time = [gettimeofday];
eval { $redis->blpop( "notakey", 5 ); };
my $elapsed = tv_interval($start_time);

cmp_ok( $elapsed, '>', 4, 'not too short' );

done_testing;
