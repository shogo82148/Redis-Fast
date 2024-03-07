use strict;
use warnings;
use Test::More;
use Redis::Fast;
use lib 't/tlib';
use Test::SpawnRedisServer;
use Test::SharedFork;
use Socket;

use constant SSL_AVAILABLE => eval { require IO::Socket::SSL };

my ($c, $t, $srv) = redis();
my $use_ssl = $t ? SSL_AVAILABLE : 0;

END {
  $c->() if $c;
  $t->() if $t;
}

my $o = Redis::Fast->new(server => $srv, name => 'my_name_is_glorious', ssl => $use_ssl, SSL_verify_mode => 0);
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
