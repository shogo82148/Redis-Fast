use strict;
use warnings;
use Config;
use Test::More;
use Test::Fatal;
use Redis::Fast;

like exception {
    Redis::Fast->new(server => "localhost:0");
}, qr/could not connect to redis server/i, 'fail to connect';

done_testing;
