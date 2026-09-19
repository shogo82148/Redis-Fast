#!perl

use warnings;
use strict;
use Test::More;
use Test::Fatal;
use Redis::Fast;
use lib 't/tlib';
use Test::SpawnRedisServer;
use File::Temp;
use POSIX;
use Time::HiRes;

sub create_dummy_dump {
    my ($c, $srv, $buf);
    eval {
        ($c, $srv) = redis();
        my $r = Redis::Fast->new(server => $srv);
        $r->set("foo$_" => 'x' x 10240) for 1..1024;
        $r->set(foo => 'bar');
        $r->save();
        my $size = -s "dump.rdb";
        open my $fh, "<", "dump.rdb" or die "fail to open dump.rdb";
        binmode($fh);
        read($fh, $buf, $size);
        close $fh;
    };
    $c->() if $c;
    return $buf;
}

ok my $dump = create_dummy_dump(), "create big dump.rdb";

mkfifo("dump.rdb", 0600) or die 'creating named pipe failed';

my $pid = fork;
if(!defined $pid) {
    die "fork failed";
} elsif(!$pid) {
    # child process
    open my $fh, ">", "dump.rdb" or die "fail to create dump.rdb";
    binmode($fh);
    select $fh;
    $| = 1;

    # write dump.rdb very slowly...(it takes about 10 seconds to complete)
    my $loading_process_events_interval_bytes = 1024 * 1024 * 2;
    my $sleep_time = 10 / (length($dump) / $loading_process_events_interval_bytes);
    while(my $b = substr $dump, 0, $loading_process_events_interval_bytes, '') {
        Time::HiRes::sleep($sleep_time);
        print $fh $b;
    }

    close $fh;
    exit;
}

my ($c, $srv) = redis(skip_unlink => 1);
END { $c->() if $c }

my $r = Redis::Fast->new(
    server => $srv,
    wait_until_loaded => 1,
);

is $r->get('foo'), 'bar';

## All done
done_testing();
