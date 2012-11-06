#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Mojo::IOLoop;

plan skip_all => 'Setup $REDIS_SERVER'
  unless $ENV{REDIS_SERVER} and $ENV{REDIS_SERVER} =~ m!^redis://.*?\@!;

plan tests => 22;

use_ok 'Mojo::Redis';

my $redis = new_ok 'Mojo::Redis' => [server => $ENV{REDIS_SERVER}, timeout => 5];
my @errors;

$redis->on(error => sub { push @errors, $_[1] });

$redis->execute(
    ping => sub {
        is $_[1], 'PONG', "Line result test";
    }
);

my $s = $redis->subscribe('foo');
$redis->quit(sub { shift->ioloop->stop; })->ioloop->start;
is int(@errors), 0, 'no errors detected' or diag join '|', @errors;
