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

use Test::LeakTrace;

no_leaks_ok {
    my $r = Redis::Fast->new(server => $srv, ssl => $use_ssl, SSL_verify_mode => 0);
} 'Redis::Fast->new';

no_leaks_ok {
    my $r = Redis::Fast->new(server => $srv, ssl => $use_ssl, SSL_verify_mode => 0);
    my $res;
    $r->set('hogehoge', 'fugafuga');
    $res = $r->get('hogehoge');
    $r->flushdb;
} 'sync get/set';

no_leaks_ok {
    my $r = Redis::Fast->new(server => $srv, ssl => $use_ssl, SSL_verify_mode => 0);
    my $res;
    $r->set('hogehoge', 'fugafuga', sub { });
    $r->get('hogehoge', sub { $res = shift });
    $r->wait_all_responses;
    $r->flushdb;
} 'async get/set';

no_leaks_ok {
    my $r = Redis::Fast->new(server => $srv, ssl => $use_ssl, SSL_verify_mode => 0);
    my $res;
    $r->rpush('hogehoge', 'fugafuga') for (1..3);
    $res = $r->lrange('hogehoge', 0, -1);
    $r->flushdb;
} 'sync list operation';

no_leaks_ok {
    my $r = Redis::Fast->new(server => $srv, ssl => $use_ssl, SSL_verify_mode => 0);
    my $res;
    $r->rpush('hogehoge', 'fugafuga') for (1..3);
    $r->lrange('hogehoge', 0, -1, sub { $res = shift });
    $r->wait_all_responses;
    $r->flushdb;
} 'async list operation';

no_leaks_ok {
    my $r = Redis::Fast->new(server => $srv, ssl => $use_ssl, SSL_verify_mode => 0);
    my $cb = sub {};
    $r->subscribe('hogehoge', $cb);
    $r->wait_for_messages(0);
    $r->unsubscribe('hogehoge', $cb);
} 'unsubscribe';

no_leaks_ok {
    my $r = Redis::Fast->new(
        server => $srv,
        reconnect => 1,
        reconnect_on_error => sub {
            my $force_reconnect = 1;
            return $force_reconnect;
        },
        ssl => $use_ssl,
        SSL_verify_mode => 0,
    );
    eval { $r->hset(1,1) };
} 'sync reconnect_on_error';

no_leaks_ok {
    my $r = Redis::Fast->new(
        server => $srv,
        reconnect => 1,
        reconnect_on_error => sub {
            my $force_reconnect = 1;
            return $force_reconnect;
        },
        ssl => $use_ssl,
        SSL_verify_mode => 0,
    );
    my $cb = sub {};
    $r->hset(1,1,$cb);
    $r->hset(2,2,$cb);
    eval { $r->wait_all_responses };
} 'async reconnect_on_error';

no_leaks_ok {
    my $r = Redis::Fast->new(server => $srv, ssl => $use_ssl, SSL_verify_mode => 0);
    $r->info();
} 'info';

done_testing;
