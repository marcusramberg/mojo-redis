#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Mojo::IOLoop;
use utf8;

plan skip_all => 'Setup $REDIS_SERVER'
  unless $ENV{REDIS_SERVER};

plan tests => 7;

use_ok 'Mojo::Redis';

my $pubsub =
  new_ok 'Mojo::Redis' => [server => $ENV{REDIS_SERVER}, timeout => 5];
my $redis = $pubsub->new($pubsub); # make clone

my $errors = 0;
my $scb=0;

$pubsub->on(error => sub { diag $_[1]; $errors++ });
$redis->on(error => sub { diag $_[1]; $errors++ });
$pubsub->on(close => sub { diag 'close'; $errors++ });
$redis->on(close => sub { diag 'close'; $errors++ });

is $pubsub->subscribe(
  'foo','bar' => sub {
    my ($s,$res, @rest)=@_;
    $scb++;
    if($scb==1) {
      is_deeply( $res, ['subscribe', 'foo', 1], "first" );
      $redis->execute(['publish','foo', 'shoo']);
      $redis->publish('bar', 'once mo');
    }
    elsif($scb==2) {
      is_deeply( $res, ['subscribe', 'bar', 2], "second" );
    }
    elsif($scb==3) {
      is_deeply( $res, ['message', 'foo','shoo'], "third");
    }
    elsif($scb==4) {
      is_deeply( $res, ['message', 'bar','once mo'], "fourth");
      $pubsub->ioloop->stop;
    }
  }
), $pubsub, 'subscribe() return $pubsub';

Mojo::IOLoop->start;
