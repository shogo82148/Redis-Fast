use strict;
use warnings;
use Test::More;
use Test::TCP;
use Redis::Fast;

sub bulk { my $s = shift; '$' . length($s) . "\r\n$s\r\n" }

# INFO replies are parsed by hand, so a reply from a broken or malicious server
# must not make the parser read past the end of the reply.
my @cases = (
    ["a:b\r\nc:d\r\n", { a => 'b', c => 'd' }, 'normal reply'],
    ["a:b\r\nc:d",     { a => 'b', c => 'd' }, 'no trailing CRLF'],
    ["a:b\r",          { a => 'b' },           'trailing CR without LF'],
    ["a:b\rc:d\r",     { a => 'b', c => 'd' }, 'lines separated by CR only'],
    ["\r",             {},                     'only CR'],
);

my $server = Test::TCP->new(
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
        my @replies = map { bulk($_->[0]) } @cases;
        while ($c = $srv->accept) {
            my $served = 0;
            while (@replies && sysread($c, my $buf, 4096)) { # INFO
                syswrite($c, shift @replies);
                $served = 1;
            }
            close $c;
            last if $served;
        }
        sleep 1 while getppid() == $ppid;
    },
);

my $r = Redis::Fast->new(server => '127.0.0.1:' . $server->port, reconnect => 0);
for my $case (@cases) {
    my (undef, $expected, $name) = @$case;
    is_deeply $r->info, $expected, $name;
}

done_testing;
