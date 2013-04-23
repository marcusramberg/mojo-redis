#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Mojo::IOLoop;
use utf8;

plan skip_all => 'Setup $REDIS_SERVER' unless $ENV{REDIS_SERVER};
plan tests => 2;

use_ok 'Mojo::Redis';

my $redis = Mojo::Redis->new(server => $ENV{REDIS_SERVER}, timeout => 0.1);
my $sub = $redis->subscribe('anything');

$sub->on(error => sub {
    is $_[1], 'Timeout', 'got timeout';
    Mojo::IOLoop->stop;
});
$sub->on(close => sub {
    diag 'close';
});
$sub->on(message => sub {
    diag join ', ', @_;
});

Mojo::IOLoop->start;
