use strict;
use warnings;
use Test::More;
use Test::Fatal;
use Redis::Fast;
use lib 't/tlib';
use Test::SpawnRedisServer;

use constant SSL_AVAILABLE => eval { require IO::Socket::SSL };

my ($c, $t, $srv) = redis();
my $use_ssl = $t ? SSL_AVAILABLE : 0;

END {
  $c->() if $c;
  $t->() if $t;
}

unless (fork()) {
    my $redis = Redis::Fast->new(
        server => $srv,
        name => 'my_name_is_glorious',
        reconnect => 1,
        read_timeout => 0.3,
        ssl => $use_ssl,
        SSL_verify_mode => 0,
    );
    eval { $redis->blpop("notakey", 1); };
    exit 0;
}

wait;

is $?, 0, "does not crash when read_timeout is smaller than BLPOP timeout";


done_testing;
