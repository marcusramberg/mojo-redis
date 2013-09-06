#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Mojo::IOLoop;
use utf8;

plan skip_all => 'Setup $REDIS_SERVER'
  unless $ENV{REDIS_SERVER};

plan tests => 14;

use_ok 'Mojo::Redis';

my $redis =
  new_ok 'Mojo::Redis' => [server => $ENV{REDIS_SERVER}, timeout => 5];

my $errors = 0;
my $scb=0;
my $mcb=0;

$redis->on(error => sub { warn $_[1]; $errors++ });
my $s = $redis->subscribe('foo','bar');

$s->on(error => sub { warn $_[1]; $errors++ });
$s->on(
  message => sub {
    my($redis, $message, $channel) = @_;
    $mcb++;
    if($mcb==1) {
      is_deeply [$message, $channel], ['shoo', 'foo'], "first message";
    }
    elsif($mcb==2) {
      is_deeply [$message, $channel], ['once mo', 'bar'], "second message";
    }
  },
);

$s->on(
  data => sub {
    my ($s,$res)=@_;
    $scb++;
    if($scb==1) {
      is_deeply $res, ['subscribe', 'foo', 1], "first";
      $redis->execute(['publish','foo', 'shoo']);
      $redis->publish('bar', 'once mo');
    }
    elsif($scb==2) {
      is_deeply $res, ['subscribe', 'bar', 2], "second";
    }
    elsif($scb==3) {
      is_deeply $res, ['message', 'foo','shoo'], "third";
    }
    elsif($scb==4) {
      is_deeply $res, ['message', 'bar','once mo'], "fourth";
    }
  }
);

my $psub_data_cb=0;
my $psub_message_cb=0;

my $pattern_subscription = $redis->psubscribe('alpha*', 'beta*');

$pattern_subscription->on(error => sub { warn $_[1]; $errors++ });

$pattern_subscription->on(
  message => sub {
    my ($redis, $message, $channel, $pattern) = @_;
    $psub_message_cb++;
    if($psub_message_cb==1) {
      is_deeply [$message, $channel, $pattern], ['Easy as 123', 'alpha.foo', 'alpha*'], "first pattern message";
    }
    elsif($psub_message_cb==2) {
      is_deeply [$message, $channel, $pattern], ['Simple as do re mi', 'beta.foo', 'beta*'], "second pattern message";
    }
  }
);

$pattern_subscription->on(
  data => sub {
    my ($s,$res)=@_;
    $psub_data_cb++;
    if($psub_data_cb==1) {
      is_deeply $res, ['psubscribe', 'alpha*', 1], "first pattern data, subscription ack #1";
      $redis->publish('alpha.foo', 'Easy as 123');
      $redis->publish('beta.foo', 'Simple as do re mi');
    }
    elsif($psub_data_cb==2) {
      is_deeply $res, ['psubscribe', 'beta*', 2], "second pattern data, subscription ack #2";
    }
    elsif($psub_data_cb==3) {
      is_deeply $res, ['pmessage', 'alpha*', 'alpha.foo', 'Easy as 123'], "third pattern data, message #1";
    }
    elsif($psub_data_cb==4) {
      is_deeply $res, ['pmessage', 'beta*','beta.foo', 'Simple as do re mi'], "fourth pattern data, message #2";
      $redis->ioloop->stop;
    }
  }
);

Mojo::IOLoop->start;
