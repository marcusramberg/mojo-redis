#!/usr/bin/env perl

use 5.008001;

use strict;
use warnings;

# Son, when you participate in sporting events,
# it's not whether you win or lose, it's how drunk you get.
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'MojoX::Redis',
    VERSION_FROM => 'lib/MojoX/Redis.pm',
    AUTHOR       => 'Sergey Zasenko <d3fin3@gmail.com>',
    PREREQ_PM => { 'Mojolicious' => '0.9003' },
    test => {TESTS => 't/*.t t/*/*.t t/*/*/*.t'}
);
