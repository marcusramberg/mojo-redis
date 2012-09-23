#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Mojo::IOLoop;
use utf8;

plan skip_all => 'Setup $REDIS_SERVER'
  unless $ENV{REDIS_SERVER};

plan tests => 8;

use_ok 'Mojo::Redis';

my $redis =
  new_ok 'Mojo::Redis' => [server => $ENV{REDIS_SERVER}, timeout => 5];

my $errors = 0;
my $scb=0;
my $mcb=0;

$redis->on(error => sub { warn $_[1]; $errors++ });
$redis->select(14);
$redis->subscribe(
  'foo','bar' => sub {
    my ($redis,$res)=@_;
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
      $redis->ioloop->stop;
    }
  }
);

$redis->subscribe_to_messages(
  qw/ foo bar /,
  sub {
    my($redis, $message, $channel) = @_;
    $mcb++;
    if($mcb==1) {
      is_deeply( [$message, $channel], ['shoo', 'foo'], "first message");
    }
    elsif($mcb==2) {
      is_deeply( [$message, $channel], ['once mo', 'bar'], "second message");
    }
  },
);

Mojo::IOLoop->start;

