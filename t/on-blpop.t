#!/usr/bin/env perl
use Mojo::Base -strict;
use Mojo::Redis;
use Test::More;

plan skip_all => 'Set REDIS_SERVER=127.0.0.1:6379' unless $ENV{REDIS_SERVER};

my $redis = Mojo::Redis->new(server => "redis://$ENV{REDIS_SERVER}/10", timeout => 5);
my $n = 0;
my($tid, @errors, @blpop);

$redis->del('test_blpop');
$redis->on(error => sub { push @errors, $_[1]; Mojo::IOLoop->stop; });
$redis->on(blpop => test_blpop => sub {
  push @blpop, [@_];
  Mojo::IOLoop->stop if @blpop == 3 or $_[1];
});

$tid = Mojo::IOLoop->recurring(0.02, sub {
  $redis->lpush(test_blpop => $tid .':' .(++$n));
  Mojo::IOLoop->remove($tid) if $n == 3;
});

Mojo::IOLoop->start;

is int(@errors), 0, 'no errors';
is_deeply(
  \@blpop,
  [map { [$redis, "", "test_blpop", "${tid}:${_}"] } 1..3],
  'blpop received expected events without error',
);

is int(keys %{$redis->{connections}}), 1, 'got a connection';

$redis->unsubscribe(blpop => 'test_blpop');
is int(keys %{$redis->{connections}}), 0, 'unsubscribe connection';

$redis->on(blpop => test_blpop => sub {});
eval { $redis->on(blpop => test_blpop => sub {}); };
like $@, qr{already subscribing to}, 'already subscribing';

$redis->disconnect;
is int(keys %{$redis->{connections}}), 0, 'disconnected connections';

done_testing;
