#!/usr/bin/env perl
use Mojo::Base -strict;
use Mojo::Redis;
use Test::More;

plan skip_all => 'Set REDIS_SERVER=127.0.0.1:6379' unless $ENV{REDIS_SERVER};

my $redis = Mojo::Redis->new(server => "redis://$ENV{REDIS_SERVER}/14", timeout => 5);
my $n = 0;
my($tid, @errors, @message);

$redis->on(error => sub { push @errors, $_[1]; Mojo::IOLoop->stop; });
$redis->on(message => "test:pub:sub" => sub {
  push @message, [@_];
  Mojo::IOLoop->stop if @message == 3 or $_[1];
});

$tid = Mojo::IOLoop->recurring(0.02, sub {
  $redis->publish("test:pub:sub" => $tid .':' .(++$n));
  Mojo::IOLoop->remove($tid) if $n == 3;
});

Mojo::IOLoop->start;

is_deeply \@errors, [], 'no errors';

is_deeply(
  \@message,
  [map { [$redis, "", "${tid}:${_}", "test:pub:sub"] } 1..3],
  'message received expected events without error',
);

is int(keys %{$redis->{connections}}), 1, 'got a connection';

$redis->on(message => test_message => sub {});
$redis->disconnect;
is int(keys %{$redis->{connections}}), 0, 'disconnected connections';

$redis->on(message => test_message => sub {});
$redis->unsubscribe(message => 'test_message');
is int(keys %{$redis->{connections}}), 0, 'unsubscribe connection';

done_testing;
