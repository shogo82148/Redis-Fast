requires 'perl', '5.008001';
requires 'Try::Tiny';

on 'configure' => sub{
    requires 'Module::Build::XSUtil' => '>=0.02';
    requires 'File::Which';
};

on 'test' => sub {
    requires 'Test::More', '0.98';
    requires 'File::Temp';
    requires 'Test::Deep';
    requires 'Test::TCP';
    requires 'Test::Fatal';
    requires 'Test::SharedFork';
    requires 'Test::LeakTrace';
    requires 'Test::Kwalitee';
    requires 'Test::Kwalitee::Extra';
};

