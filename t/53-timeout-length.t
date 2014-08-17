use strict;
use warnings;
use Test::More;
use Test::Fatal;
use Redis::Fast;
use lib 't/tlib';
use Test::SpawnRedisServer;
use Time::HiRes qw/gettimeofday tv_interval/;

my ($c, $srv) = redis();
END { $c->() if $c }

my $redis = Redis::Fast->new(server => $srv, name => 'my_name_is_glorious', reconnect => 1, write_timeout => 1);

my $start_time = [gettimeofday];
eval { $redis->blpop("notakey", 5); };
my $elapsed = tv_interval($start_time);

cmp_ok( $elapsed, '>', 4, 'not too short' );

done_testing;
