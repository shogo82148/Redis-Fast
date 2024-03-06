#!perl

use warnings;
use strict;
use Test::More;
use Test::Deep;
use Redis::Fast::Hash;
use lib 't/tlib';
use Test::SpawnRedisServer;

use constant SSL_AVAILABLE => eval { require IO::Socket::SSL };

my ($c, $t, $srv) = redis();
my $use_ssl = $t ? SSL_AVAILABLE : 0;

END {
  $c->() if $c;
  $t->() if $t;
}

## Setup
my %my_hash;
ok(my $redis = tie(%my_hash, 'Redis::Fast::Hash', 'my_hash', server => $srv, ssl => $use_ssl, SSL_verify_mode => 0), 'tied to our test redis-server');
ok($redis->ping, 'pinged fine');
isa_ok($redis, 'Redis::Fast::Hash');


## Direct access
subtest 'direct access' => sub {
  %my_hash = ();
  cmp_deeply(\%my_hash, {}, 'empty list ok');

  %my_hash = (a => 'foo', b => 'bar', c => 'baz');
  cmp_deeply(\%my_hash, { a => 'foo', b => 'bar', c => 'baz' }, 'Set multiple values ok');

  $my_hash{b} = 'BAR';
  cmp_deeply(\%my_hash, { a => 'foo', b => 'BAR', c => 'baz' }, 'Set single value ok');

  is($my_hash{c}++, 'baz', 'get single value ok');
  is(++$my_hash{c}, 'bbb', '... even with post/pre-increments');
};


## Hash functions
subtest 'hash functions' => sub {
  ok(my @keys = keys(%my_hash), 'keys ok');
  cmp_deeply(\@keys, bag(qw( a b c )), '... resulting list as expected');

  ok(my @values = values(%my_hash), 'values ok');
  cmp_deeply(\@values, bag(qw( foo BAR bbb )), '... resulting list as expected');

  %my_hash = reverse %my_hash;
  cmp_deeply(\%my_hash, { foo => 'a', BAR => 'b', bbb => 'c' }, 'reverse() worked');
};


## Cleanup
%my_hash = ();
cmp_deeply(\%my_hash, {}, 'empty list ok');

done_testing();
