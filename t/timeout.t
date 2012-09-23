use warnings;
use strict;
use Test::More;
use Mojo::Redis;

plan skip_all => 'Setup $REDIS_SERVER' unless $ENV{REDIS_SERVER};
my $redis = Mojo::Redis->new;

$redis->on(error => sub { diag $_[1] });
$redis->timeout(2);
$redis->get('test');
$redis->subscribe(foo => sub {
  my($redis) = @_;
  my $ioloop = $redis->ioloop;
  $redis->timeout(30);
  is $redis->timeout, 30, 'changed master timeout to 30';
  is $ioloop->stream($redis->{_connection})->timeout, 30, 'also changed master stream timeout';
  is $ioloop->stream(keys %{ $redis->{_ids} })->timeout, 30, 'also changed pubsub stream timeout';
  Mojo::IOLoop->stop;
});

is $redis->timeout, 2, 'changed master timeout to 2';
Mojo::IOLoop->start;
done_testing;
