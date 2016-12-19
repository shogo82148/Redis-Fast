#!perl

use warnings;
use strict;
use Test::More;
use Test::Fatal;
use Redis::Fast;
use lib 't/tlib';
use Test::SpawnRedisServer;

my ($c, $srv) = redis(timeout => 3); # redis connection timeouts within 3 seconds.
END { $c->() if $c }

# Reconnect once
# when
## 1. reconnect is greater than 0
## 2. and reconnect_on_error returns a value greater than and equal to 0
## 3. and a specified time seconds elapsed

my $sync_call_hset = sub {
    my ($client, $hint)  = @_;
    like (exception { $client->hset(1,1) },
        qr{ERR wrong number of arguments for 'hset' command},
        'syntax error')
        or diag "hint=$hint";
    return 'sync';
};
my $async_call_hset = sub {
    my ($client, $hint)  = @_;
    my $_cb_call_count = 0;
    my $_cb = sub {
        my ($ret, $error) = @_;
        is $error, "ERR wrong number of arguments for 'hset' command"
            or diag "_cb_call_count=$_cb_call_count, hint=$hint";
        ok !$ret
            or diag "_cb_call_count=$_cb_call_count, hint=$hint";
        $_cb_call_count++;
    };
    $client->hset(1,1,$_cb);
    $client->hset(2,2,$_cb);
    $client->wait_all_responses;
    is $_cb_call_count, 2;
    return 'async';
};


# Check a condition 1.

subtest 'reconnect option is 0: reconnect_on_error is not called' => sub {
    for my $call_hset ($sync_call_hset, $async_call_hset) {
        my $cb_call_count = 0;
        my $r = Redis::Fast->new(
            reconnect          => 0, # do not trigger reconnection.
            server             => $srv,
            reconnect_on_error => sub { $cb_call_count++ },
        );
        my $hint = $call_hset->($r, "reconnect is 0");
        is $cb_call_count, 0, 'reconnect_on_error is not called'
            or diag "call=$hint";
    }
};

subtest 'reconnect option is 1: reconnect_on_error is called once' => sub {
    for my $call_hset ($sync_call_hset, $async_call_hset) {
        my $cb_call_count = 0;
        my $r = Redis::Fast->new(
            reconnect          => 1, # trigger reconnection until 1 second elapsed.
            server             => $srv,
            reconnect_on_error => sub {
                my ($error, $ret, $cmd) = @_;

                # increment a counter to test it later.
                $cb_call_count++;

                # tests each argument.
                is $error, "ERR wrong number of arguments for 'hset' command";
                ok !$ret;
                is $cmd, 'HSET';
                return 0; # 0 means invake reconnection as soon as possible.
            },
        );
        my $hint = $call_hset->($r, "reconnect is 1");
        is $cb_call_count, 1, 'reconnect_on_error is called once'
            or diag "call=$hint";
    }
};


# Check a condition 2.

subtest "reconnect_on_error returns -1: redis ERR doesn't trigger reconnection" => sub {
    for my $call_hset ($sync_call_hset, $async_call_hset) {
        my $connect_count = 0;
        my $cb_call_count = 0;
        my $r = Redis::Fast->new(
            reconnect          => 1,
            server             => $srv,
            on_connect         => sub { $connect_count++ },
            reconnect_on_error => sub {
                $cb_call_count++;
                return -1; # reconnect_on_error returns -1
            },
        );
        my $hint = $call_hset->($r, "reconnect_on_error returns -1");
        is $connect_count, 1, "redis ERR doesn't trigger reconnection";
        if ($hint eq 'async') {
            is $cb_call_count, 2, 'call reconnect_on_error each async call for hset'
                or diag "cb_return_value=-1 hint=$hint";
        } else {
            is $cb_call_count, 1, 'call reconnect_on_error once'
                or diag "cb_return_value=-1, hint=$hint";
        }
    }
};

subtest "reconnect_on_error returns 0: redis ERR triggers reconnection" => sub {
    for my $call_hset ($sync_call_hset, $async_call_hset) {
        my $connect_count = 0;
        my $cb_call_count = 0;
        my $r = Redis::Fast->new(
            reconnect          => 1,
            server             => $srv,
            on_connect         => sub { $connect_count++ },
            reconnect_on_error => sub {
                $cb_call_count++;
                return 0; # reconnect_on_error returns 0
            },
        );
        my $hint = $call_hset->($r, "reconnect_on_error returns 0");
        is $connect_count, 2, "redis ERR triggers reconnection";

        # If $cb_return_value is 0 and then $self->need_reconnect is set,
        # calling the reconnect_on_error cb again is useless cost.
        is $cb_call_count, 1, 'call reconnect_on_error once'
            or diag "cb_return_value=-1, hint=$hint";
    }
};


# Check a condition 3.

subtest "reconnection will not be triggered until specified seconds elapsed." => sub {
    for my $call_hset ($sync_call_hset, $async_call_hset) {
        my $hint;
        my $cb_call_count = 0;
        my $cb_return_value = 0;
        my $r = Redis::Fast->new(
            reconnect          => 1,
            server             => $srv,
            reconnect_on_error => sub {
                $cb_call_count++;
                return $cb_return_value;
            },
        );

        # reconnect if the redis returns ERR,
        # and next reconnection will be triggered.
        $cb_return_value = 0;

        $hint = $call_hset->($r, $cb_return_value);
        is $cb_call_count, 1, 'call reconnect_on_error once'
            or diag "cb_return_value=$cb_return_value, call=$hint";

        # reconnect if the redis returns ERR,
        # and next reconnection will not be triggered until 1 second elapsed.
        $cb_return_value = 1;

        $hint = $call_hset->($r, $cb_return_value);
        is $cb_call_count, 2, 'call reconnect_on_error twice'
            or diag "cb_return_value=$cb_return_value, call=$hint";

        # reconnection is not triggered
        # because $cb_return_value seconds have not passed since the last reconnection.
        $hint = $call_hset->($r, $cb_return_value);
        is $cb_call_count, 2, 'call reconnect_on_error twice'
            or diag "cb_return_value=$cb_return_value, call=$hint";
    }
};

subtest "reconnection will be triggered after specified seconds elapsed." => sub {
    for my $call_hset ($sync_call_hset, $async_call_hset) {
        my $hint;
        my $cb_call_count = 0;
        my $cb_return_value = 0;
        my $r = Redis::Fast->new(
            reconnect          => 1,
            server             => $srv,
            reconnect_on_error => sub {
                $cb_call_count++;
                return $cb_return_value;
            },
        );

        # reconnect if the redis returns ERR,
        # and next reconnection will be triggered.
        $cb_return_value = 0;

        $hint = $call_hset->($r, $cb_return_value);
        is $cb_call_count, 1, 'call reconnect_on_error once'
            or diag "cb_return_value=$cb_return_value, call=$hint";

        # reconnect if the redis returns ERR,
        # and next reconnection will not be triggered until 1 second elapsed.
        $cb_return_value = 1;

        $hint = $call_hset->($r, $cb_return_value);
        is $cb_call_count, 2, 'call reconnect_on_error twice'
            or diag "cb_return_value=$cb_return_value, call=$hint";

        # wait for $cb_return_value seconds to pass since the last reconnection.
        # +1 second is a buffer.
        sleep $cb_return_value + 1;

        # reconnection is triggered
        # because $cb_return_value seconds have passed since the last reconnection.
        $hint = $call_hset->($r, $cb_return_value);
        is $cb_call_count, 3, 'call reconnect_on_error twice'
            or diag "cb_return_value=$cb_return_value, call=$hint";
    }
};

done_testing();
