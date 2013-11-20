use Mojo::Base -strict;
use Mojo::IOLoop;
use Mojo::Redis;
use Test::More;
use utf8;

plan skip_all => 'Setup $REDIS_SERVER' unless $ENV{REDIS_SERVER};
plan tests => 6;

my $redis = Mojo::Redis->new(server => $ENV{REDIS_SERVER}, timeout => 3);
my(@mcb, @scb);

my $s = $redis->psubscribe('alpha*', 'beta*');

$_->on(error => sub {
  diag $_[1];
  $redis->ioloop->stop;
}) for $redis, $s;

my $psub_message_cb=0;

$s->on(
  message => sub {
    my($s, $message, $channel, $pattern) = @_;

    push @mcb, [ $message, $channel, $pattern ];

    if(@scb == 4 and @mcb == 2) {
      Mojo::IOLoop->stop;
    }
  }
);

$s->on(
  data => sub {
    my($s, $res)=@_;

    push @scb, $res;

    if(@scb == 1) {
      $redis->publish('alpha.foo', 'Easy as 123');
      $redis->publish('beta.foo', 'Simple as do re mi');
    }
    if(@scb == 4 and @mcb == 2) {
      Mojo::IOLoop->stop;
    }
  }
);

Mojo::IOLoop->start;

is_deeply $mcb[0], ['Easy as 123', 'alpha.foo', 'alpha*'], "first pattern message";
is_deeply $mcb[1], ['Simple as do re mi', 'beta.foo', 'beta*'], "second pattern message";

is_deeply $scb[0], ['psubscribe', 'alpha*', 1], "first pattern data, subscription ack #1";
is_deeply $scb[1], ['psubscribe', 'beta*', 2], "second pattern data, subscription ack #2";
is_deeply $scb[2], ['pmessage', 'alpha*', 'alpha.foo', 'Easy as 123'], "third pattern data, message #1";
is_deeply $scb[3], ['pmessage', 'beta*','beta.foo', 'Simple as do re mi'], "fourth pattern data, message #2";
