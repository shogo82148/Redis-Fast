use strict;
use warnings;
use Test::More;
use Test::TCP;
use Redis::Fast;

sub bulk { my $s = shift; '$' . length($s) . "\r\n$s\r\n" }

# start a server which sends $replies to the first client after it sends a command.
sub start_server {
    my $replies = shift;
    return Test::TCP->new(
        code => sub {
            my $port = shift;
            my $srv = IO::Socket::INET->new(
                LocalAddr => '127.0.0.1',
                LocalPort => $port,
                Listen    => 5,
                ReuseAddr => 1,
            ) or die "failed to start server: $!";
            # serve only one client, and exit when the client process exits, even if it crashes.
            # skip the connections from Test::TCP checking the port, which send nothing.
            my $ppid = getppid();
            my $c;
            while ($c = $srv->accept) {
                last if sysread($c, my $buf, 4096); # SUBSCRIBE foo
                close $c;
            }
            syswrite($c, $replies);
            select undef, undef, undef, 0.1;
            close $c;
            sleep 1 while getppid() == $ppid;
        },
    );
}

# A server can send subscription replies that do not match the client's requests.
# hiredis keeps the callback of a channel until all of its pending subscriptions are confirmed,
# so the client must not free the callback context just because an unsubscribe reply arrived.
my %scenarios = (
    'unsubscribe before the subscription is confirmed' =>
        "*3\r\n" . bulk('unsubscribe') . bulk('foo') . ":0\r\n",
    'duplicated subscription confirmation' =>
        ("*3\r\n" . bulk('subscribe') . bulk('foo') . ":1\r\n") x 2
        . "*3\r\n" . bulk('unsubscribe') . bulk('foo') . ":0\r\n",
);

for my $name (sort keys %scenarios) {
    # the callback of foo is still registered in hiredis, so the messages reach it
    my $server = start_server($scenarios{$name} . ("*3\r\n" . bulk('message') . bulk('foo') . bulk('bar')) x 3);
    my $r = Redis::Fast->new(server => '127.0.0.1:' . $server->port, reconnect => 0);
    local $SIG{__WARN__} = sub {}; # messages for a topic without callbacks
    $r->subscribe('foo', sub {});
    eval { $r->wait_for_messages(1) for 1..3 };
    undef $r; # hiredis calls the remaining callbacks with a NULL reply here
    pass "survived: $name";
}

# RESP3 servers send subscription replies as pushes
{
    my $server = start_server(
        ">3\r\n" . bulk('subscribe') . bulk('foo') . ":1\r\n"
        . ">3\r\n" . bulk('message') . bulk('foo') . bulk('bar')
    );
    my $r = Redis::Fast->new(server => '127.0.0.1:' . $server->port, reconnect => 0);
    my @messages;
    my $ok = eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 5;
        $r->subscribe('foo', sub { push @messages, $_[0] });
        $r->wait_for_messages(1) until @messages;
        alarm 0;
        1;
    };
    alarm 0;
    ok $ok, 'subscribe with RESP3 push replies' or diag $@;
    is_deeply \@messages, ['bar'], 'receive a message pushed by RESP3';
}

done_testing;
