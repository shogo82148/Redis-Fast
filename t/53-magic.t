use strict;
use warnings;
use Test::More;
use Redis::Fast;
use lib 't/tlib';
use Test::SpawnRedisServer;

my ($c, $srv) = redis();
END { $c->() if $c }

my $redis = Redis::Fast->new(server => $srv, name => 'magic', reconnect=>1);

# substr uses "Perl Magic", see http://perldoc.perl.org/functions/substr.html for more details.
# We need to consider this case.
ok $redis->set("key1", substr( "asdfg", 0, 4 ));
is $redis->get("key1"), "asdf";

$redis->__std_cmd("set", "key2", substr( "asdfg", 0, 4 ));
is $redis->__std_cmd("get", "key2"), "asdf";

done_testing;
