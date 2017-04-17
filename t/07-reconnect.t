#!perl

use warnings;
use strict;
use Test::More;
use Test::Fatal;
use Time::HiRes qw(gettimeofday tv_interval);
use Redis::Fast;
use lib 't/tlib';
use Test::SpawnRedisServer;
use Net::EmptyPort qw(empty_port);
use version;
use POSIX qw(setlocale LC_ALL);

my ($c, $srv) = redis(timeout => 1);
END { $c->() if $c }


subtest 'Command without connection, no reconnect' => sub {
  ok(my $r = Redis::Fast->new(reconnect => 0, server => $srv), 'connected to our test redis-server');
  ok($r->quit, 'close connection to the server');

  like(exception { $r->set(reconnect => 1) }, qr{Not connected to any server}, 'send ping without reconnect',);
};

subtest 'Command without connection or timeout, with database change, with reconnect' => sub {
  ok(my $r = Redis::Fast->new(reconnect => 2, server => $srv), 'connected to our test redis-server');

  ok($r->select(4), 'send command with reconnect');
  ok($r->set(reconnect => $$), 'send command with reconnect');
  ok($r->quit, 'close connection to the server');
  is($r->get('reconnect'), $$, 'reconnect with read errors before write');
};


subtest 'Reconnection discards pending commands' => sub {
  ok(my $r = Redis::Fast->new(reconnect => 2, server => $srv), 'connected to our test redis-server');

  my $processed_pending = 0;
  $r->dbsize(sub { $processed_pending++ });

  _wait_for_redis_timeout();
  ok($r->set(foo => 'bar'), 'send command with reconnect');

  is($processed_pending, 0, 'pending command discarded on reconnect');
};


subtest 'INFO commands with extra logic triggers reconnect' => sub {
  ok(my $r = Redis::Fast->new(reconnect => 2, server => $srv), 'connected to our test redis-server');

  ok($r->quit, 'close connection to the server');

  my $info = $r->info;
  is(ref $info, 'HASH', 'reconnect on INFO command');
};


subtest 'KEYS commands with extra logic triggers reconnect' => sub {
  ok(my $r = Redis::Fast->new(reconnect => 2, server => $srv), 'connected to our test redis-server');

  ok($r->flushdb, 'delete all keys');
  ok($r->set(reconnect => $$), 'set known key');

  ok($r->quit, 'close connection to the server');

  my @keys = $r->keys('*');
  is_deeply(\@keys, ['reconnect'], 'reconnect on KEYS command');
};


subtest 'PING commands with extra logic triggers reconnect' => sub {
  ok(my $r = Redis::Fast->new(reconnect => 2, server => $srv), 'connected to our test redis-server');

  _wait_for_redis_timeout();

  my $res = $r->ping;
  ok($res, 'reconnect on PING command');

  ok($r->quit, 'close connection to the server');
  $res = $r->ping;
  ok(!$res, 'QUIT command disables reconnect on PING command');
};


subtest "Bad commands don't trigger reconnect" => sub {
  ok(my $r = Redis::Fast->new(reconnect => 2, server => $srv), 'connected to our test redis-server');

  my $prev_sock = $r->__sock;
  like(
    exception { $r->set(bad => reconnect => 1) },
    qr{ERR wrong number of arguments for 'set' command|ERR syntax error},
    'Bad commands still die',
  );
  is($r->__sock, $prev_sock, "... and don't trigger a reconnect");
};


subtest 'Reconnect code clears sockect ASAP' => sub {
  ok(my $r = Redis::Fast->new(reconnect => 3, server => $srv), 'connected to our test redis-server');
  _wait_for_redis_timeout();
  is(exception { $r->quit }, undef, "Quit doesn't die if we are already disconnected");
};


subtest "Reconnect gives up after timeout" => sub {
  ok(my $r = Redis::Fast->new(reconnect => 3, server => $srv), 'connected to our test redis-server');
  $c->();    ## Make sure the server is dead

  my $t0 = [gettimeofday];
  like(
    exception { $r->set(reconnect => 1) },
    qr{Could not connect to Redis server at},
    'Eventually it gives up and dies',
  );
  ok(tv_interval($t0) > 3, '... minimum value for the reconnect reached');
};

subtest "Reconnect during transaction" => sub {
  $c->();    ## Make previous server is dead

  my $port = empty_port();
  ok(($c, $srv) = redis(port => $port, timeout => 1), "spawn redis on port $port");
  ok(my $r = Redis::Fast->new(reconnect => 3, server => $srv), 'connected to our test redis-server');

  ok($r->multi(), 'start transacion');
  ok($r->set('reconnect_1' => 1), 'set first key');

  $c->();
  ok(($c, $srv) = redis(port => $port, timeout => 1), "respawn redis on port $port");

  like(exception { $r->set('reconnect_2' => 2) }, qr{reconnect disabled inside transaction}, 'set second key');

  $r->connect(); #reconnect
  is($r->exists('reconnect_1'), 0, 'key "reconnect_1" should not exist');
  is($r->exists('reconnect_2'), 0, 'key "reconnect_2" should not exist');
};

subtest "exec does not trigger reconnect" => sub {
  $c->();    ## Make previous server is dead

  my $port = empty_port();
  ok(($c, $srv) = redis(port => $port, timeout => 1), "spawn redis on port $port");
  ok(my $r = Redis::Fast->new(reconnect => 3, server => $srv), 'connected to our test redis-server');

  ok($r->multi(), 'start transacion');
  ok($r->set('reconnect_1' => 1), 'set first key');

  $c->();
  ok(($c, $srv) = redis(port => $port, timeout => 1), "respawn redis on port $port");

  like(exception { $r->exec() }, qr{reconnect disabled inside transaction}, 'exec');

  $r->connect(); #reconnect
  is($r->exists('reconnect_1'), 0, 'key "reconnect_1" should not exist');
};

subtest "multi should trigger reconnect" => sub {
  $c->();    ## Make previous server is dead

  my $port = empty_port();
  ok(($c, $srv) = redis(port => $port, timeout => 1), "spawn redis on port $port");
  ok(my $r = Redis::Fast->new(reconnect => 3, server => $srv), 'connected to our test redis-server');

  $c->();
  ok(($c, $srv) = redis(port => $port, timeout => 1), "respawn redis on port $port");

  ok($r->multi(), 'start transacion');
  ok($r->set('reconnect' => 1), 'set key');
  ok($r->exec(), 'execute transaction');

  $c->();
  ok(($c, $srv) = redis(port => $port, timeout => 1), "respawn redis on port $port");

  ok($r->set('reconnect' => 1), 'setting key should not fail');
};

subtest "Reconnect works after WATCH + MULTI + EXEC" => sub {
  $c->();    ## Make previous server is dead

  my $port = empty_port();
  ok(($c, $srv) = redis(port => $port, timeout => 1), "spawn redis on port $port");
  ok(my $r = Redis::Fast->new(reconnect => 3, server => $srv), 'connected to our test redis-server');

  ok($r->set('watch' => 'watch'), 'set watch key');
  ok($r->watch('watch'), 'start watching key');
  ok($r->multi(), 'start transacion');
  ok($r->set('reconnect' => 1), 'set key');
  ok($r->exec(), 'execute transaction');

  $c->();
  ok(($c, $srv) = redis(port => $port, timeout => 1), "respawn redis on port $port");

  ok($r->set('reconnect' => 1), 'setting key should not fail');
};

subtest "Reconnect works after WATCH + MULTI + DISCARD" => sub {
  $c->();    ## Make previous server is dead

  my $port = empty_port();
  ok(($c, $srv) = redis(port => $port, timeout => 1), "spawn redis on port $port");
  ok(my $r = Redis::Fast->new(reconnect => 3, server => $srv), 'connected to our test redis-server');

  ok($r->set('watch' => 'watch'), 'set watch key');
  ok($r->watch('watch'), 'start watching key');
  ok($r->multi(), 'start transacion');
  ok($r->set('reconnect' => 1), 'set key');
  ok($r->discard(), 'dscard transaction');

  $c->();
  ok(($c, $srv) = redis(port => $port, timeout => 1), "respawn redis on port $port");

  ok($r->set('reconnect' => 1), 'setting second key should not fail');
};

subtest "Disconnect inside MULTI" => sub {
  $c->();    ## Make previous server is dead

  my $port = empty_port();
  ok(($c, $srv) = redis(port => $port, timeout => 10), "spawn redis on port $port");
  ok(my $r = Redis::Fast->new(reconnect => 2, server => $srv, cnx_timeout => 1,
                              read_timeout => 1, write_timeout => 1), 'connected to our test redis-server');

  setlocale(LC_ALL, "C");
  plan skip_all => 'DEBUG SLEEP not implemented'
    if version->parse($r->info()->{redis_version}) < version->parse(2.2.12);
  ok($r->multi(), 'start transacion');
  ok($r->set('reconnect' => 1), 'set key');
  $r->debug("sleep", 2);
  like(exception { $r-> exec() }, qr/Error while reading from Redis server: Resource temporarily unavailable/i, "timeout error");
  ok(!$r->ping(), 'disconnected');
};

subtest "Disconnect inside WATCH + MULTI" => sub {
  $c->();    ## Make previous server is dead

  my $port = empty_port();
  ok(($c, $srv) = redis(port => $port, timeout => 10), "spawn redis on port $port");
  ok(my $r = Redis::Fast->new(reconnect => 2, server => $srv, cnx_timeout => 1,
                              read_timeout => 1, write_timeout => 1), 'connected to our test redis-server');
  plan skip_all => 'DEBUG SLEEP not implemented'
    if version->parse($r->info()->{redis_version}) < version->parse(2.2.12);

  setlocale(LC_ALL, "C");
  ok($r->set('watch' => 'watch'), 'set watch key');
  ok($r->watch('watch'), 'start watching key');
  ok($r->multi(), 'start transacion');
  ok($r->set('reconnect' => 1), 'set key');
  $r->debug("sleep", 2);
  like(exception { $r-> exec() }, qr/Error while reading from Redis server: Resource temporarily unavailable/i, "timeout error");
  ok(!$r->ping(), 'disconnected');
};

done_testing();


sub _wait_for_redis_timeout {
  ## Redis will timeout clients after 100 internal server loops, at
  ## least 10 seconds (even with a timeout 1 on the config) so we sleep
  ## a bit more hoping the timeout did happen. Not perfect, patches
  ## welcome
  diag('Sleeping 11 seconds, waiting for Redis to timeout...');
  sleep(11);
}
