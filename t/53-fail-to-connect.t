use strict;
use warnings;
use Config;
use Test::More;
use Test::Fatal;
use Redis::Fast;

like exception {
    Redis::Fast->new(server => "localhost:0");
}, qr/could not connect to redis server/i, 'fail to connect';

my $redis = Redis::Fast->new(
   reconnect => 0,
   every => 50_000,
   no_auto_connect_on_new => 1,
   server => '127.0.0.1:6379',
   write_timeout => 0.2,
   read_timeout => 0.2,
   cnx_timeout => 0.2,
);

eval { $redis->info(); };
eval { $redis->info(); };
eval { $redis->info(); };

done_testing;
