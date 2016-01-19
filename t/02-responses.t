#!perl

use warnings;
use strict;
use Test::More;
use Test::Fatal;
use Test::Deep;
use Redis::Fast;
use IO::Socket::UNIX;
use Test::UNIXSock;
use Parallel::ForkManager;

sub r {
    my ($response, $test) = @_;
    test_unix_sock(
        server => sub {
            my $path = shift;
            my $sock = IO::Socket::UNIX->new(
                Local     => $path,
                Listen    => 1,
                Type      => SOCK_STREAM,
            ) or die "Cannot open server socket: $!";

            my $res = join '', map "$_\r\n", @$response;
            my $pm = Parallel::ForkManager->new(10);
            while(my $remote = $sock->accept) {
                my $pid = $pm->start and next;
                <$remote>; # ignore commands from client
                print {$remote} $res;
                $pm->finish;
            }
        },
        client => sub {
            my $path = shift;
            ok(my $r = Redis::Fast->new(sock => $path, reconnect => 1), 'connected to our test redis-server');
            $test->($r);
        },
    );
}

## -ERR responses
r(['-you must die!!'] => sub {
    my $r = shift;
    like(
        exception { $r->get('hoge') },
        qr/you must die!!/,
        'Error response detected'
    );
});

## +TEXT responses
r(['+all your text are belong to us'] => sub {
      is shift->get('hoge'), 'all your text are belong to us', 'Text response ok';
});


## :NUMBER responses
r([':234'] => sub {
      is shift->get('hoge'), 234, 'Integer response ok';
});


## $SIZE PAYLOAD responses
r(['$19', "Redis\r\nis\r\ngreat!\r\n"] => sub {
      is shift->get('hoge'), "Redis\r\nis\r\ngreat!\r\n", 'Size+payload response ok';
});

r(['$0', ""] => sub {
      is shift->get('hoge'), "", 'Zero-size+payload response ok';
});

r(['$-1', ""] => sub {
      is shift->get('hoge'), undef, 'Negative-size+payload response ok';
});


## Multi-bulk responses
r(['*4', '$5', 'Redis', ':42', '$-1', '+Cool stuff'] => sub {
      cmp_deeply([shift->get('hoge')], ['Redis', 42, undef, 'Cool stuff'], 'Simple multi-bulk response ok');
});


## Nested Multi-bulk responses
r(['*5', '$5', 'Redis', ':42', '*4', ':1', ':2', '$4', 'hope', '*2', ':4', ':5', '$-1', '+Cool stuff'] => sub {
      cmp_deeply(
          [shift->get('hoge')],
          ['Redis', 42, [1, 2, 'hope', [4, 5]], undef, 'Cool stuff'],
          'Nested multi-bulk response ok',
      );
});


## Nil multi-bulk responses
r(['*-1'] => sub {
      is shift->get('hoge'), undef, 'Read a NIL multi-bulk response';
});


## Multi-bulk responses with nested error
r(['*3', '$5', 'Redis', '-you must die!!', ':42'] => sub {
      my $r = shift;
      like(
          exception { $r->get('hoge') },
          qr/\[get\] you must die!!/,
          'Nested errors must usually throw exceptions'
      );
});

r(['*3', '$5', 'Redis', '-you must die!!', ':42'] => sub {
      my $r = shift;
      my $result;
      $r->exec('hoge', sub { $result = [@_] });
      $r->wait_all_responses;
      is_deeply(
          $result,
          [[['Redis', undef], [undef, 'you must die!!'], [42, undef]], undef,],
          'Nested errors must be collected in collect-errors mode'
      );
});

done_testing();
