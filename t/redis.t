#!/usr/bin/end perl

use strict;
use warnings;

use Test::More;
use Mojo::IOLoop;
use utf8;

plan skip_all => 'Setup $REDIS_SERVER'
  unless $ENV{REDIS_SERVER};

plan tests => 10;

use_ok 'MojoX::Redis';

my $redis =
  new_ok 'MojoX::Redis' => [server => $ENV{REDIS_SERVER}, timeout => 5];

$redis->execute(ping => sub { is_deeply shift, ['PONG'], "Line result test" })
  ->execute(
    qwe => sub {
        is_deeply shift, undef, 'Uknown command result';
        is $redis->error, q|ERR unknown command 'QWE'|;
    }
  )->execute(
    set => [test => 'test_ok'],
    sub { is_deeply shift, ['OK'], "Another line result" }
  )->execute(
    get => 'test',
    sub { is_deeply shift, ['test_ok'], "Bulk result" }
  )->execute(del => 'test')->execute(rpush => [test => 'test1'])
  ->execute(rpush => [test => 'test2'])->execute(
    lrange => ['test', 0, -1],
    sub { is_deeply shift, ["test1", "test2"], "Multy-bulk result"; }
  )->execute(set => [test => 'привет'])->execute(
    get => 'test',
    sub { is_deeply shift, ['привет'], "Unicode test" }
  )->execute(
    ping => sub {
        is_deeply shift, ['PONG'], "Last check";
        Mojo::IOLoop->singleton->stop;
    }
  );

Mojo::IOLoop->singleton->start;

