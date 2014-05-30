use t::Helper;
use Mojo::Redis;

my $port = generate_port();

{
  my $server = Mojo::IOLoop->server({ port => $port }, sub { Mojo::IOLoop->stop; });
  my $redis = Mojo::Redis->new(server => "127.0.0.1:$port", timeout => 2);

  $redis->connect;
  ok !$redis->connected, 'not connected';
  Mojo::IOLoop->start;
  ok $redis->connected, 'connected';

  Mojo::IOLoop->stream($redis->{connection})->close;
  ok !$redis->connected, 'closed';
}

{
  my $ioloop = Mojo::IOLoop->new;
  my $server = $ioloop->server({ port => $port }, sub { $ioloop->stop; });
  my $redis = Mojo::Redis->new(server => "127.0.0.1:$port", timeout => 2, ioloop => $ioloop);

  $redis->connect;
  $ioloop->start;
  ok $redis->connected, 'connected to custom ioloop';

  undef $ioloop;
  undef $redis->{ioloop};
  ok !$redis->connected, 'ioloop went away';
}

done_testing;
