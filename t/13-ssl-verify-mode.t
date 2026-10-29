use strict;
use warnings;
use Test::More;
use Test::Fatal;
use Test::TCP;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Redis::Fast;

like exception {
    Redis::Fast->new(no_auto_connect_on_new => 1, ssl => 1, SSL_verify_mode => $_);
}, qr/Invalid SSL_verify_mode/, "reject SSL_verify_mode $_" for ('foo', '-1', '1.5', 16);

SKIP: {
    skip 'IO::Socket::SSL is required to run a TLS server', 6 unless eval { require IO::Socket::SSL };
    test_tls();
}

done_testing;

sub test_tls {
    # t/ssl/cert.pem is a self-signed certificate, so it must be rejected unless the verification is disabled.
    my $server = Test::TCP->new(
        code => sub {
            my $port = shift;
            my $srv = IO::Socket::SSL->new(
                LocalAddr     => '127.0.0.1',
                LocalPort     => $port,
                Listen        => 5,
                ReuseAddr     => 1,
                SSL_cert_file => 't/ssl/cert.pem',
                SSL_key_file  => 't/ssl/key.pem',
            ) or die "failed to start TLS server: " . IO::Socket::SSL->errstr;
            while (1) {
                my $c = $srv->accept or next;
                while (sysread($c, my $buf, 4096)) {
                    syswrite($c, "+PONG\r\n");
                }
                close $c;
            }
        },
    );
    my $addr = '127.0.0.1:' . $server->port;

    # the verification may fail either in new or in ping
    my $ping = sub {
        my @args = @_;
        return eval {
            my $r = Redis::Fast->new(server => $addr, ssl => 1, reconnect => 0, @args);
            $r->ping;
        };
    };

    ok !$ping->(), 'the certificate is verified by default';
    ok !$ping->(SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_PEER()), 'SSL_VERIFY_PEER rejects the certificate';
    ok !$ping->(SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_PEER() | IO::Socket::SSL::SSL_VERIFY_FAIL_IF_NO_PEER_CERT()),
        'combined flags reject the certificate';
    is $ping->(SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE()), 'PONG', 'SSL_VERIFY_NONE accepts the certificate';

    # SSL_verify_mode must work even when IO::Socket::SSL is unavailable
    my $tmp = tempdir(CLEANUP => 1);
    make_path("$tmp/IO/Socket");
    open my $fh, '>', "$tmp/IO/Socket/SSL.pm" or die $!;
    print {$fh} "die qq(mock missing IO::Socket::SSL\\n);";
    close $fh;

    for my $case ([undef, ''], [0, 'PONG']) {
        my ($mode, $expected) = @$case;
        my $out = qx{$^X -Mblib -I$tmp -MRedis::Fast -e '
            print eval {
                Redis::Fast->new(server => "$addr", ssl => 1, reconnect => 0, \@ARGV ? (SSL_verify_mode => \$ARGV[0]) : ())->ping;
            } // "";
        ' @{[ defined $mode ? $mode : '' ]}};
        is $out, $expected, 'without IO::Socket::SSL, SSL_verify_mode ' . (defined $mode ? $mode : 'default');
    }
}
