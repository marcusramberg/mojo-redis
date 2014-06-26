use Mojo::Base -base;
use Mojo::Redis2;
use Test::More;

plan skip_all => 'Missing MOJO_REDIS_URL=redis://localhost/14' unless $ENV{MOJO_REDIS_URL};

my $redis = Mojo::Redis2->new;
my ($err, $res);

{
  diag 'pipelined=0';
  run();
  like $err, qr{WRONGTYPE}, 'pipelined=0: rpush failed';
  is_deeply $res, ['OK', undef, undef], 'pipelined=0: got set+rpush+ping response' or diag join '|', @$res;
}

{
  diag 'pipelined=1';
  $redis->pipelined;
  run();
  like $err, qr{WRONGTYPE}, 'pipelined=1: rpush failed';
  is_deeply $res, ['OK', undef, 'PONG'], 'pipelined=1: got set+rpush+ping response' or diag join '|', @$res;
}

done_testing;

sub run {
  Mojo::IOLoop->delay(
    sub {
      my ($delay) = @_;
      $redis->set('mojo:redis2:scalar' => 42)->rpush('mojo:redis2:scalar', 'foo')->ping->execute($delay->begin);
    },
    sub {
      (my $delay, $err, $res) = @_;
      Mojo::IOLoop->stop;
    }
  );

  Mojo::IOLoop->start;
}
