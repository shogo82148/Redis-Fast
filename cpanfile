requires 'perl', '5.008001';

on 'configure' => sub{
    requires 'Module::Build::XSUtil' => '>=0.02';
};

on 'test' => sub {
    requires 'Test::More', '0.98';
    requires 'File::Temp';
    requires 'Test::Deep';
    requires 'Test::TCP';
};

