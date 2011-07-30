#!/usr/bin/env perl

use 5.008001;

use strict;
use warnings;

# Son, when you participate in sporting events,
# it's not whether you win or lose, it's how drunk you get.
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME          => 'MojoX::Redis',
    AUTHOR        => 'Sergey Zasenko <undef@cpan.org>',
    LICENSE       => 'artistic_2',
    VERSION_FROM  => 'lib/MojoX/Redis.pm',
    ABSTRACT_FROM => 'lib/MojoX/Redis.pm',

    BUILD_REQUIRES => {'Test::More' => '0.88'},
    PREREQ_PM      => {
        'Mojolicious'     => '1.22',
        'Protocol::Redis' => '1.0'
    },
    META_MERGE => {
        resources => {
            repository => 'http://github.com/und3f/mojox-redis',
            license    => 'http://dev.perl.org/licenses/',
            bugtracker => 'https://github.com/und3f/mojox-redis/issues',
        }
    }
);
