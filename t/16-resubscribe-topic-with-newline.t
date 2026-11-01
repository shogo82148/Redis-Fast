use warnings;
use strict;
use Test::More;
use Redis::Fast;
use lib 't/tlib';
use Test::SpawnRedisServer;

use constant SSL_AVAILABLE => eval { require IO::Socket::SSL };

my ($c, $t, $srv) = redis(requires_version => '2.8.12'); # CLIENT KILL TYPE
my $use_ssl = $t ? SSL_AVAILABLE : 0;
END {
    $c->() if $c;
    $t->() if $t;
}

# Subscriptions are restored on reconnect from keys like "message:$channel".
# A channel name containing "\nmessage:" must not be restored as another channel.
my $channel = "x\nmessage:target";
my $pattern = "y\npmessage:*";

my $pub = Redis::Fast->new(server => $srv, ssl => $use_ssl, SSL_verify_mode => 0);
my $sub = Redis::Fast->new(server => $srv, ssl => $use_ssl, SSL_verify_mode => 0, reconnect => 1);
$sub->subscribe($channel, sub {});
$sub->psubscribe($pattern, sub {});
is_deeply [$pub->pubsub('channels')], [$channel], 'subscribed to the channel';
is $pub->pubsub('numpat'), 1, 'subscribed to the pattern';

# force the subscriber to reconnect, which restores the subscriptions
$pub->client('kill', 'type', 'pubsub');
eval { $sub->wait_for_messages(1) };

is_deeply [$pub->pubsub('channels')], [$channel], 'the same channel is restored';
is_deeply [$pub->pubsub('channels', 'target')], [], 'another channel is not subscribed';
is $pub->pubsub('numpat'), 1, 'the pattern is restored';
is $pub->publish('anything', 'msg'), 0, 'another pattern is not subscribed';

done_testing;
