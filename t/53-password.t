#!perl

use warnings;
use strict;
use Test::More;
use Test::Fatal;
use Redis::Fast;
use lib 't/tlib';
use Test::SpawnRedisServer;

my $password = 'very-very-long-strong-password';
my ($c, $srv) = redis(
    password => $password,
);
END { $c->() if $c }

subtest 'no password' => sub {
    my $o;
    is(
        exception { $o = Redis::Fast->new(server => $srv) },
        undef, 'connect is success',
    );

    like(
        exception { $o->get('foo') },
        qr/\[get\] (NOAUTH Authentication required|ERR operation not permitted)/,
        'but cannot execute any command except `auth`',
    );
};

subtest 'wrong password' => sub {
    my $o;
    like(
        exception { $o = Redis::Fast->new(server => $srv, password => 'wrong-password') },
        qr/Redis server refused password/, 'connect is fail',
    );
};

subtest 'correct password' => sub {
    my $o;
    is(
        exception { $o = Redis::Fast->new(server => $srv, password => $password) },
        undef, 'connect is success',
    );

    is(
        exception { $o->get('foo') },
        undef,
        'can exeecute all command',
    );
};

## All done
done_testing();
