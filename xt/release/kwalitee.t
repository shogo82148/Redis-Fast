BEGIN {
    unless ($ENV{AUTHOR_TESTING}) {
        require Test::More;
        Test::More::plan(skip_all => 'Skip because AUTHOR_TESTING is unset');
    }
}

use Test::More;

use Test::Kwalitee::Extra qw(:retry 5 :experimental);
