BEGIN {
    if (-e '.git') {       
        require Test::More;
	Test::More::plan(skip_all=>'Installing from a git repository omiting Kwalitee tests.');
    }
}

use Test::More;

use Test::Kwalitee::Extra qw(:retry 1 :experimental);
