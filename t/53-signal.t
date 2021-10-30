use strict;
use warnings;
use Test::More;
use Test::Fatal;
use Redis::Fast;
use lib 't/tlib';
use Test::SpawnRedisServer;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

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
    my $start_time = clock_gettime(CLOCK_MONOTONIC);
    my $sig_time;
    local $SIG{ALRM} = sub { $sig_time = clock_gettime(CLOCK_MONOTONIC); };
    alarm 1;
    $redis->blpop('abc', 5);
    my $end_time = clock_gettime(CLOCK_MONOTONIC);
    cmp_ok $sig_time - $start_time, '<=', 2, 'the signal handler is executed as soon as possible';
    cmp_ok $end_time - $start_time, '>=', 4, 'the signal does not unblock the Redis command';
};

subtest 'die in signal' => sub {
    my $start_time = clock_gettime(CLOCK_MONOTONIC);
    local $SIG{ALRM} = sub { die "ALARM\n"; };
    alarm 1;
    is exception {  $redis->blpop('abc', 20); }, "ALARM\n";
    my $end_time = clock_gettime(CLOCK_MONOTONIC);
    cmp_ok $end_time - $start_time, '<=', 2, 'the signal unblocks the Redis command';
    diag $start_time;
};

done_testing;

