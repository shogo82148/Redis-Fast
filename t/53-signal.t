use strict;
use warnings;
use Test::More;
use Test::Fatal;
use Redis::Fast;
use lib 't/tlib';
use Test::SpawnRedisServer;

my ($c, $srv) = redis();
END { $c->() if $c }


my $redis;
is(
  exception { $redis = Redis::Fast->new(server => $srv, name => 'my_name_is_glorious') },
  undef, 'connected to our test redis-server',
);
ok($redis->ping, 'ping');

$redis->select(2);

{
    local $SIG{ALRM} = sub { die "ALARM\n"; };
    alarm 1;
    is exception {  $redis->blpop('abc', 20); }, "ALARM\n";
}

done_testing;

