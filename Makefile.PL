#!/usr/bin/env perl

use 5.008001;

use strict;
use warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
    NAME          => 'Mojo::Redis',
    AUTHOR        => 'Marcus Ramberg <mramberg@cpan.org>',
    LICENSE       => 'artistic_2',
    VERSION_FROM  => 'lib/Mojo/Redis.pm',
    ABSTRACT_FROM => 'lib/Mojo/Redis.pm',

    BUILD_REQUIRES => {'Test::More' => '0.88'},
    PREREQ_PM      => {
        'Mojolicious'     => '3.0',
        'Protocol::Redis' => '1.0',
        'Encode'          => 0,
    },
    META_MERGE => {
        resources => {
            repository => 'http://github.com/marcusramberg/mojo-redis',
            license    => 'http://dev.perl.org/licenses/',
            bugtracker => 'https://github.com/marcusramberg/mojo-redis/issues',
        }
    }
);
