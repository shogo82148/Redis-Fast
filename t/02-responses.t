#!perl

use warnings;
use strict;
use Test::More;
use Test::Fatal;
use Test::Deep;
use IO::String;
use Redis::Fast;
use IO::Socket::INET;
use Test::TCP;


sub r {
    my ($response, $test) = @_;
    test_tcp(
        server => sub {
            my $port = shift;
            my $sock = IO::Socket::INET->new(
                LocalPort => $port,
                LocalAddr => '127.0.0.1',
                Proto     => 'tcp',
                Listen    => 5,
                Type      => SOCK_STREAM,
            ) or die "Cannot open server socket: $!";

            my $res = join '', map "$_\r\n", @$response;
            while(my $remote = $sock->accept) {
                print {$remote} $res;
            }
        },
        client => sub {
            my $port = shift;
            ok(my $r = Redis::Fast->new(server => "127.0.0.1:$port"), 'connected to our test redis-server');
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
