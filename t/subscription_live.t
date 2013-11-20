use Mojo::Base -strict;
use Mojo::IOLoop;
use Mojo::Redis;
use Test::More;
use utf8;

plan skip_all => 'Setup $REDIS_SERVER' unless $ENV{REDIS_SERVER};
plan tests => 6;

my $redis = Mojo::Redis->new(server => $ENV{REDIS_SERVER}, timeout => 3);
my(@mcb, @scb);

my $s = $redis->subscribe('foo','bar');

$_->on(error => sub {
  diag $_[1];
  $redis->ioloop->stop;
}) for $redis, $s;

$s->on(
  message => sub {
    my($s, $message, $channel) = @_;

    push @mcb, [ $message, $channel ];

    if(@scb == 4 and @mcb == 2) {
      Mojo::IOLoop->stop;
    }
  },
);

$s->on(
  data => sub {
    my($s, $res)=@_;

    push @scb, $res;

    if(@scb == 1) {
      $redis->execute(['publish','foo', 'shoo']);
      $redis->publish('bar', 'once mo');
    }
    if(@scb == 4 and @mcb == 2) {
      Mojo::IOLoop->stop;
    }
  }
);

Mojo::IOLoop->start;

is_deeply $mcb[0], ['shoo', 'foo'], "first message";
is_deeply $mcb[1], ['once mo', 'bar'], "second message";

is_deeply $scb[0], ['subscribe', 'foo', 1], "first";
is_deeply $scb[1], ['subscribe', 'bar', 2], "second";
is_deeply $scb[2], ['message', 'foo','shoo'], "third";
is_deeply $scb[3], ['message', 'bar','once mo'], "fourth";
