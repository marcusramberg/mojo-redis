#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Mojo::IOLoop;
use utf8;

plan skip_all => 'Setup $REDIS_SERVER'
  unless $ENV{REDIS_SERVER};

plan tests => 3;

use_ok 'Mojo::Redis';

my $redis = new_ok 'Mojo::Redis' => [server => $ENV{REDIS_SERVER}, timeout => 5];
my $result;

$redis->select(14);
$redis->del('test')->multi->rpush(test => 'ok')->lrange(test => 0, -1)->exec(
    sub {
        my ($redis, $res) = @_;
        $result = $res;
        $redis->ioloop->stop;
    }
)->ioloop->start;

is_deeply $result, [1, ['ok']], 'got lrange result';
