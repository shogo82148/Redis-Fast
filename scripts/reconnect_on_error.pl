#!/usr/bin/perl

use warnings;
use strict;
use 5.010;
use lib 'lib';
use Test::More;
use Redis::Fast;

my $test_mode_sync=0;

my $r = Redis::Fast->new(
    reconnect          => 1,
    server             => 'localhost:6380',
    reconnect_on_error => sub {
        my ($error, $ret, $command) = @_;
        $ret ||= "";

        my $next_reconnect = -1;
        if ($error =~ /READONLY You can't write against a read only slave/) {
            $next_reconnect = 2;
        }

        diag "cb: error=$error, ret=$ret, command=$command, next=$next_reconnect";
        return $next_reconnect;
    },
);

my $key = 'hoge';
my $ret = $r->get($key);
ok !$ret, "no data" or diag $ret;

sleep 30;

my $value = 'fuga';
for my $i (1..30) {
    if ($test_mode_sync) {
        eval { $r->setex($key, 1, $value) };
        if ($@) {
            diag "Sleep and next: tried $i time(s), ignore error=$@";
            sleep 1;
            next;
        }
        $ret = $r->get($key);
        is $ret, $value, 'did reconnect with master'
            or die '[BUG] test code is broken';
        done_testing();
        exit 0;
    } else {
        my $error;
        $r->setex($key, 1, $value, sub {
            my ($ret, $_error) = @_;
            unless ($_error) {
                $ret = $r->get($key);
                is $ret, $value, 'did reconnect with master'
                    or die '[BUG] test code is broken';
                done_testing();
                exit 0;
            }
            $error = $_error;
        });
        $r->wait_all_responses;
        diag "Sleep and next: tried $i time(s), ignore error=$error";
        sleep 1;
    }
}

ok 0, 'did not reconnect with master';

done_testing();

__END__
# Manual for an operation test
## NOTE: Turn off `close-on-slave-write` parameter for the ElastiCache Redis.
## 1. Set a redis cluster endpoint url to a server parameter.
## 2. Manual failover to hoge-redis2
aws elasticache modify-replication-group \
--replication-group-id hoge-redis-cluster \
--primary-cluster-id hoge-redis2 \
--apply-immediately
## 3. READONLY errors happen until reconnecting with a new master endpoint.
## 4. This tests are ok after a reconnection.
