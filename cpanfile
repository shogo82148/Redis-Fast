requires 'perl', '5.014000';
requires 'Try::Tiny';
requires 'Time::HiRes' => '>=1.77';

on 'configure' => sub{
    requires 'Module::Build::XSUtil' => '>=0.02';
    requires 'File::Which';
};

on 'test' => sub {
    requires 'Test::More', '0.98';
    requires 'File::Temp';
    requires 'Test::Deep';
    requires 'Test::TCP';
    requires 'Test::UNIXSock';
    requires 'Parallel::ForkManager';
    requires 'Test::Fatal';
    requires 'Test::SharedFork';
    requires 'Test::LeakTrace';
    requires 'Digest::SHA';
};

on 'develop' => sub {
    requires 'Test::Kwalitee';
    requires 'Test::Kwalitee::Extra';
};
