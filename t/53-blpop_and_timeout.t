use strict;
use warnings;
use Test::More;
use Test::Fatal;
use Redis::Fast;
use lib 't/tlib';
use Test::SpawnRedisServer;

my ($c, $srv) = redis();
END { $c->() if $c }

unless (fork()) {
    my $redis = Redis::Fast->new(server => $srv, name => 'my_name_is_glorious', reconnect=>1, read_timeout  => 0.3);
    eval { $redis->blpop("notakey", 1); };
    exit 0;
}

wait;

is $?, 0, "does not crash when read_timeout is smaller than BLPOP timeout";


done_testing;
