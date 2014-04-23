use Test::More;
use t::LeakTrap;

plan skip_all => 'Set REDIS_SERVER=127.0.0.1:6379' unless $ENV{REDIS_SERVER};

{
  my $redis = Mojo::Redis->new(server => "redis://$ENV{REDIS_SERVER}/14", timeout => 5);
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

  is_deeply \@errors, [], 'no errors';

  is_deeply(
    \@blpop,
    [map { [$redis, "", "${tid}:${_}", "test_blpop"] } 1..3],
    'blpop received expected events without error',
  );

  is int(keys %{$redis->{connections}}), 1, 'got a connection';

  $redis->on(blpop => test_blpop => sub {});
  $redis->unsubscribe(blpop => 'test_blpop');
  is int(keys %{$redis->{connections}}), 0, 'unsubscribe connection';

  $redis->on(blpop => test_blpop => sub {});
  $redis->disconnect;
  is int(keys %{$redis->{connections}}), 0, 'disconnected connections';
}

is_deeply [values %::trap], [], 'no leakage' or diag join ' ', 'leak obj:', sort values %::trap;

done_testing;
