use strict;
use warnings;
use Test::More;
use Redis::Fast;
use lib 't/tlib';
use Test::SpawnRedisServer;
use Test::SharedFork;
use Socket;

my ($c, $srv) = redis();
END { $c->() if $c }
my $o = Redis::Fast->new(server => $srv, name => 'my_name_is_glorious');
is $o->info->{connected_clients}, 1;
my $localport = $o->__get_port;

note "fork safe"; {
    if (my $pid = fork) {
        $o->incr("test-fork");
        is $o->__get_port, $localport, "same port on parent";
        waitpid($pid, 0);
    }
    else {
        $o->incr("test-fork");
        isnt $o->__get_port, $localport, "different port on child";
        is $o->info->{connected_clients}, 2, "2 clients connected";
        exit 0;
    }

    is $o->get('test-fork'), 2;
};

done_testing;
