use strict;
use warnings;
use Test::More;
use Redis::Fast;
use lib 't/tlib';
use Test::SpawnRedisServer;

my ($c, $srv) = redis();
END { $c->() if $c }

my $redis = Redis::Fast->new(server => $srv, name => 'blpop_test', reconnect=>1, cnx_timeout   => 0.2, read_timeout  => 1);

unless (fork()) {
    # it will exit with read timeout
    eval { $redis->blpop("somekey", 3); };
    exit;
}

sleep 2;
$redis->rpush("somekey", 4);
sleep 1;
is $redis->lpop("somekey"), 4, 'blpop is time out while lpop is success';

wait;

done_testing;
