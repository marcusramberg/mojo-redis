use Test::More;
use t::LeakTrap;

plan skip_all => 'Set REDIS_SERVER=127.0.0.1:6379' unless $ENV{REDIS_SERVER};

my $publisher = Mojo::Redis->new(server => "redis://$ENV{REDIS_SERVER}/14", timeout => 5);

{
  my $redis = Mojo::Redis->new(server => "redis://$ENV{REDIS_SERVER}/14", timeout => 5);
  my $n = 0;
  my(@errors, @message);

  $redis->on(error => sub { push @errors, $_[1]; Mojo::IOLoop->stop; });
  $redis->once(message => "test:pub:sub" => sub {
    shift;
    push @message, [@_];
    Mojo::IOLoop->stop;
  });

  Mojo::IOLoop->timer(0.02, sub {
    $publisher->publish("test:pub:sub" => ++$n);
  });

  Mojo::IOLoop->timer(1 => sub { Mojo::IOLoop->stop; });
  Mojo::IOLoop->start;

  is_deeply \@errors, [], 'no errors';

  is_deeply(
    \@message,
    [[ "", "1", "test:pub:sub" ]],
    'message received expected events without error',
  );

  is int(keys %{$redis->{connections}}), 1, 'got a connection';

  $redis->once(message => test_message => sub {});
  $redis->disconnect;
  is int(keys %{$redis->{connections}}), 0, 'disconnected connections';

  $redis->once(message => test_message => sub {});
  $redis->unsubscribe(message => 'test_message');
  is int(keys %{$redis->{connections}}), 0, 'unsubscribe connection';
}

undef $publisher;

is_deeply [values %::trap], [], 'no leakage' or diag join ' ', 'leak obj:', sort values %::trap;

done_testing;
