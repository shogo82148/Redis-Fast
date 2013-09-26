package builder::MyBuilder;
use strict;
use warnings FATAL => 'all';
use 5.008005;
use base 'Module::Build::XSUtil';
use Config;

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
    $self->do_system($Config{make}, '-C', 'deps/hiredis', 'static');
    return $self;
}

1;
