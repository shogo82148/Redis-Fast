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
        extra_linker_flags => ["deps/hiredis/libhiredis$Config{lib_ext}"],
    );

    my $make;
    if ($^O =~ m/bsd$/ && $^O !~ m/gnukfreebsd$/) {
        my $gmake = which('gmake');
        unless (defined $gmake) {
            print "'gmake' is necessary for BSD platform.\n";
            exit 0;
        }
        $make = $gmake;
    } else {
        $make = $Config{make};
    }

    $self->do_system($make, '-C', 'deps/hiredis', 'static');
    return $self;
}

1;
