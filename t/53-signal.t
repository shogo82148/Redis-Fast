use strict;
use warnings;
use Test::More;
use Test::Fatal;
use Redis::Fast;
use lib 't/tlib';
use Test::SpawnRedisServer;
use Time::HiRes qw();

my ($c, $srv) = redis();
END { $c->() if $c }


my $redis;
is(
  exception { $redis = Redis::Fast->new(server => $srv, name => 'my_name_is_glorious') },
  undef, 'connected to our test redis-server',
);
ok($redis->ping, 'ping');

$redis->select(2);

subtest 'signal' => sub {
    my $start = Time::HiRes::time;
    my $sig;
    local $SIG{ALRM} = sub { $sig = Time::HiRes::time };
    alarm 1;
    $redis->blpop('abc', 5);
    my $end = Time::HiRes::time;
    cmp_ok $sig - $start, '<=', 2, 'the signal handler is executed as soon as possible';
    cmp_ok $end - $start, '>=', 4, 'the signal does not unblock the Redis command';
};

subtest 'die in signal' => sub {
    my $start = Time::HiRes::time;
    local $SIG{ALRM} = sub { die "ALARM\n"; };
    alarm 1;
    is exception {  $redis->blpop('abc', 20); }, "ALARM\n";
    my $end = Time::HiRes::time;
    cmp_ok $end - $start, '<=', 2, 'the signal unblocks the Redis command';
};

done_testing;

