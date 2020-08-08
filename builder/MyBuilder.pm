package builder::MyBuilder;
use strict;
use warnings FATAL => 'all';
use 5.008005;
use base 'Module::Build::XSUtil';
use Config;
use File::Which qw(which);

sub new {
    my ( $class, %args ) = @_;
    my $self = $class->SUPER::new(
        %args,
        generate_ppport_h    => 'src/ppport.h',
        c_source             => 'src',
        xs_files             => { './src/Redis__Fast.xs' => './lib/Redis/Fast.xs', },
        include_dirs         => ['src', 'deps/hiredis'],
        extra_linker_flags   => ["deps/hiredis/libhiredis$Config{lib_ext}"],

        test_requires => {
            "Digest::SHA"           => "0",
            "File::Temp"            => "0",
            "Parallel::ForkManager" => "0",
            "Test::Deep"            => "0",
            "Test::Fatal"           => "0",
            "Test::LeakTrace"       => "0",
            "Test::More"            => "0.98",
            "Test::SharedFork"      => "0",
            "Test::TCP"             => "0",
            "Test::UNIXSock"        => "0",
        },
    );

    my $make;
    if ($^O =~ m/(bsd|dragonfly)$/ && $^O !~ m/gnukfreebsd$/) {
        my $gmake = which('gmake');
        unless (defined $gmake) {
            print "'gmake' is necessary for BSD platform.\n";
            exit 0;
        }
        $make = $gmake;
    } else {
        $make = $Config{make};
    }
    if (-e '.git') {
        unless (-e 'deps/hiredis/Makefile') {
            $self->do_system('git','submodule','update','--init');
        }
    }
    $self->do_system($make, '-C', 'deps/hiredis', 'static');
    return $self;
}

1;
