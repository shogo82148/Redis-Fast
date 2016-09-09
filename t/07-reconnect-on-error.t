#!perl

use warnings;
use strict;
use Test::More;
use Test::Fatal;
use Redis::Fast;
use lib 't/tlib';
use Test::SpawnRedisServer;

my ($c, $srv) = redis(timeout => 1);
END { $c->() if $c }

# Reconnect once
# when
## 1. reconnect is greater than 0
## 2. and reconnect_on_error returns a value greater than and equal to 0
## 3. and a specified time seconds elapsed

sub new_redis_fast {
    my ($reconnect, $reconnect_on_error) = @_;
    return Redis::Fast->new(
        reconnect          => $reconnect,
        server             => $srv,
        reconnect_on_error => $reconnect_on_error,
    );
}
my $cb_call_count = 0;
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
{
    my $cb = sub {
        my ($error, $ret, $cmd) = @_;

        # increment a counter to test it later.
        $cb_call_count++;

        # tests each argument.
        is $error, "ERR wrong number of arguments for 'hset' command";
        ok !$ret;
        is $cmd, 'HSET';
        return 0;
    };

    for my $reconnect (0, 1) {
        for my $call_hset ($sync_call_hset, $async_call_hset) {
            my $r = new_redis_fast($reconnect, $cb);
            my $hint = $call_hset->($r, $reconnect);

            if ($reconnect == 0) {
                is $cb_call_count, 0, 'do not call reconnect_on_error'
                    or diag "call=$hint";
            } else {
                is $cb_call_count, 1, 'call reconnect_on_error once'
                    or diag "call=$hint";
            }

            # reset a counter
            $cb_call_count = 0;
        }
    }
}

# Check a condition 2.
{
    my $get_client_list = sub {
        my $r_get_conn = new_redis_fast();
        my $list = $r_get_conn->client_list;
        my @list = split "\n", $list;
        return @list;
    };
    my $kill_all_client = sub {
        my $r_kill_conn = new_redis_fast();
        my $ret = $r_kill_conn->client_kill('TYPE', 'normal');
        undef $r_kill_conn;

        my @list = $get_client_list->();
        unless (scalar @list == 1) {
            die "[BUG] client should be only r_get_con itself: list=" . (join "\n", @list);
        }
    };

    my $cb = sub {
        my $cb_return_value = shift;

        return sub {
            my ($error, $ret, $cmd) = @_;

            # increment a counter to test it later.
            $cb_call_count++;

            # quit to test whether reconnect or not.
            $kill_all_client->();

            return $cb_return_value;
        }
    };

    for my $cb_return_value (-1, 0) {
        for my $call_hset ($sync_call_hset, $async_call_hset) {
            my $reconnect = 1;

            my $r = new_redis_fast($reconnect, $cb->($cb_return_value));
            my $hint = $call_hset->($r, $cb_return_value);

            if ($cb_return_value == -1 && $hint eq 'async') {
                # If $cb_return_value is 0 and then $self->need_recoonect is set,
                # calling the reconnect_on_error cb again is useless cost.
                is $cb_call_count, 2, 'call reconnect_on_error each async call for hset'
                    or diag "cb_return_value=$cb_return_value, hint=$hint";
            } else {
                is $cb_call_count, 1, 'call reconnect_on_error once'
                    or diag "cb_return_value=$cb_return_value, hint=$hint";
            }

            my @client_list = $get_client_list->();
            if ($cb_return_value == -1) {
                is scalar @client_list, 1, 'do not reconnect after a contrived quit'
                    or diag explain \@client_list . ", hint=$hint";
            } else {
                is scalar @client_list, 2, 'reconnect after a contrived quit'
                    or diag explain \@client_list . ", hint=$hint";
            }
            # reset a counter
            $cb_call_count = 0;
        }
    }
}

# Check a condition 3.
{
    my $cb_return_value = 0;
    my $cb = sub {
        my ($error, $ret, $cmd) = @_;

        # increment a counter to test it later.
        $cb_call_count++;

        return $cb_return_value;
    };

    my $reconnect = 1;

    # Do not call a reconnect_on_error before a second elapse.
    {
        for my $call_hset ($sync_call_hset, $async_call_hset) {
            my $r = new_redis_fast($reconnect, $cb);

            for my $_cb_return_value (0, 1, 2) {
                $cb_return_value = $_cb_return_value;
                my $hint = $call_hset->($r, $_cb_return_value);

                if ($_cb_return_value == 0) {
                    # once: call a cb and return 0.
                    is $cb_call_count, 1, 'call reconnect_on_error once'
                        or diag "cb_return_value=$_cb_return_value, call=$hint";
                } else {
                    # twice: do not wait, so call a cb and return 1.
                    is $cb_call_count, 2, 'call reconnect_on_error twice, not 3 or 4 times'
                        or diag "cb_return_value=$_cb_return_value, call=$hint";
                }
                # do not sleep a second
                # do not reset a counter
            }
            # reset a counter
            $cb_call_count = 0;
        }
    }

    # Call a reconnect_on_error after a second elapse.
    {
        for my $call_hset ($sync_call_hset, $async_call_hset) {
            my $r = new_redis_fast($reconnect, $cb);
            for my $_cb_return_value (0, 1, 2) {
                $cb_return_value = $_cb_return_value;
                my $hint = $call_hset->($r, $_cb_return_value);

                if ($_cb_return_value == 0) {
                    # once: call a cb and return 0.
                    is $cb_call_count, 1, 'call reconnect_on_error once'
                        or diag "cb_return_value=$_cb_return_value, call=$hint";
                } elsif ($_cb_return_value == 1) {
                    # twice: do not wait, so call a cb and return 1.
                    is $cb_call_count, 2, 'call reconnect_on_error twice'
                        or diag "cb_return_value=$_cb_return_value, call=$hint";
                } else {
                    # 3 times: wait for a second, so call a cb and return 2.
                    is $cb_call_count, 3, 'call reconnect_on_error 3 times, not 4 times'
                        or diag "cb_return_value=$_cb_return_value, call=$hint";
                }

                # A second elapsed
                sleep 1;

                # do not reset a counter
            }
            # reset a counter
            $cb_call_count = 0;
        }
    }
}

done_testing();
