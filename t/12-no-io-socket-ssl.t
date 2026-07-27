use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);

my $tmp = tempdir(CLEANUP => 1);
my $ssl_dir = "$tmp/IO/Socket";
make_path($ssl_dir);

open my $fh, '>', "$ssl_dir/SSL.pm" or die $!;
print {$fh} "die qq(mock missing IO::Socket::SSL\\n);";
close $fh;

my $ok = system(
    $^X,
    '-Mblib',
    "-I$tmp",
    '-MRedis::Fast',
    '-we',
    'my $r = eval { Redis::Fast->new(no_auto_connect_on_new => 1) }; die $@ if $@;',
);

is($ok, 0, 'new() works without IO::Socket::SSL when ssl options are not given');

done_testing;
