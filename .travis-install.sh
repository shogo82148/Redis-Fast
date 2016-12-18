#!/bin/bash

set -ex

# install language pack for testing error messages.
if which apt-get >/dev/null; then
    sudo apt-get update
    sudo apt-get --reinstall install -qq language-pack-en language-pack-ja
fi

# reinstall perl because some modules are too old.

# Root owner of $HOME/perl5 causes a perlbrew installation error.
if [[ $TRAVIS_OS_NAME = osx ]] && [ -e "$HOME/perl5" ] ; then sudo chown -R "$(whoami):staff" "$HOME/perl5"; fi
if [ ! -e "$HOME/perl5/perlbrew/etc/bashrc" ]; then curl -L http://install.perlbrew.pl | bash; fi
source ~/perl5/perlbrew/etc/bashrc
if [ ! -e "$HOME/travis-perl-helpers/init" ]; then
    git clone git://github.com/travis-perl/helpers ~/travis-perl-helpers

    # Existence of prebuilt perl causes a build-perl error.
    if [[ $TRAVIS_OS_NAME = osx ]]; then perlbrew list | xargs perlbrew uninstall --yes; fi

    source ~/travis-perl-helpers/init
    if [[ $TRAVIS_OS_NAME = osx ]]; then export REBUILD_PERL=1; fi

    build-perl
    cpan-install App::cpanminus
else
    source ~/travis-perl-helpers/init
fi


# install redis.
if [ ! -e "redis-bin/redis-server" ]; then
    wget "https://github.com/antirez/redis/archive/$REDIS_VERSION.tar.gz"
    tar xzf "$REDIS_VERSION.tar.gz"
    make -C "redis-$REDIS_VERSION"
    mkdir -p redis-bin
    cp "redis-REDIS_VERSION/src/redis-server" redis-bin/redis-server
fi

# install CPAN modules.
cpanm --notest Minilla Test::CPAN::Meta Test::Pod Test::MinimumVersion::Fast
cpanm --quiet --with-develop --installdeps --notest .
