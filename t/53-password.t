#!perl

use warnings;
use strict;
use Test::More;
use Test::Fatal;
use Redis::Fast;
use lib 't/tlib';
use Test::SpawnRedisServer;

use constant SSL_AVAILABLE => eval { require IO::Socket::SSL };

my $password = 'very-very-long-strong-password';
my ($c, $t, $srv) = redis(
    password => $password,
);
my $use_ssl = $t ? SSL_AVAILABLE : 0;

END {
  $c->() if $c;
  $t->() if $t;
}

subtest 'no password' => sub {
    my $o;
    is(
        exception { $o = Redis::Fast->new(server => $srv, ssl => $use_ssl, SSL_verify_mode => 0) },
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
        exception { $o = Redis::Fast->new(server => $srv, password => 'wrong-password', ssl => $use_ssl, SSL_verify_mode => 0) },
        qr/Redis server refused password/, 'connect is fail',
    );
};

subtest 'correct password' => sub {
    my $o;
    is(
        exception { $o = Redis::Fast->new(server => $srv, password => $password, ssl => $use_ssl, SSL_verify_mode => 0) },
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
