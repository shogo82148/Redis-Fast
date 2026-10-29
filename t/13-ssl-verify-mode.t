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
    skip 'IO::Socket::SSL is required to run a TLS server', 8 unless eval { require IO::Socket::SSL };
    test_tls();
}

done_testing;

sub start_server {
    my ($cert, $key) = @_;
    return Test::TCP->new(
        code => sub {
            my $port = shift;
            my $srv = IO::Socket::SSL->new(
                LocalAddr     => '127.0.0.1',
                LocalPort     => $port,
                Listen        => 5,
                ReuseAddr     => 1,
                SSL_cert_file => $cert,
                SSL_key_file  => $key,
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
}

sub test_tls {
    # t/ssl/cert.pem is a self-signed certificate, so it must be rejected unless the verification is disabled.
    my $server = start_server('t/ssl/cert.pem', 't/ssl/key.pem');
    my $addr = '127.0.0.1:' . $server->port;

    # the verification may fail either in new or in ping
    my $ping = sub {
        my ($addr, @args) = @_;
        return eval {
            my $r = Redis::Fast->new(server => $addr, ssl => 1, reconnect => 0, @args);
            $r->ping;
        };
    };

    # Both certificates are signed by the same trusted CA, so only the host name decides which one is accepted.
    {
        require IO::Socket::SSL::Utils;
        my $dir = tempdir(CLEANUP => 1);
        my ($ca_cert, $ca_key) = IO::Socket::SSL::Utils::CERT_create(CA => 1, subject => { CN => 'Redis::Fast test CA' });
        IO::Socket::SSL::Utils::PEM_cert2file($ca_cert, "$dir/ca.pem");
        for my $c ([ip => [IP => '127.0.0.1']], [other => [DNS => 'redis.example.com']]) {
            my ($name, $san) = @$c;
            my ($cert, $key) = IO::Socket::SSL::Utils::CERT_create(
                subject         => { CN => $san->[1] },
                subjectAltNames => [$san],
                issuer          => [$ca_cert, $ca_key],
                purpose         => 'server',
            );
            IO::Socket::SSL::Utils::PEM_cert2file($cert, "$dir/$name-cert.pem");
            IO::Socket::SSL::Utils::PEM_key2file($key, "$dir/$name-key.pem");
        }

        local $ENV{SSL_CERT_FILE} = "$dir/ca.pem";
        my $ip    = start_server("$dir/ip-cert.pem", "$dir/ip-key.pem");
        my $other = start_server("$dir/other-cert.pem", "$dir/other-key.pem");
        is $ping->('127.0.0.1:' . $ip->port), 'PONG', 'a trusted certificate for the host name is accepted';
        ok !$ping->('127.0.0.1:' . $other->port), 'a trusted certificate for another host name is rejected';
    }

    ok !$ping->($addr), 'the certificate is verified by default';
    ok !$ping->($addr, SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_PEER()), 'SSL_VERIFY_PEER rejects the certificate';
    ok !$ping->($addr, SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_PEER() | IO::Socket::SSL::SSL_VERIFY_FAIL_IF_NO_PEER_CERT()),
        'combined flags reject the certificate';
    is $ping->($addr, SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE()), 'PONG', 'SSL_VERIFY_NONE accepts the certificate';

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
