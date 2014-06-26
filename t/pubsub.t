use Mojo::Base -base;
use Mojo::Redis2;
use Test::More;

plan skip_all => 'Missing MOJO_REDIS_URL=redis://localhost/14' unless $ENV{MOJO_REDIS_URL};

my $redis = Mojo::Redis2->new;
my ($err, $res, $n, $tid, @messages);

{
  $redis->subscribe("mojo:redis:test", sub {
    diag "subscribe mojo:redis:test";
    (my $redis, $err, $res) = @_;
    $n++;
    $redis->publish("mojo:redis:test" => "message $n")->execute;
  });
  $redis->on(message => sub {
    shift;
    push @messages, [message => @_];
    $redis->psubscribe("mojo:redis:ch*", sub {
      $n++;
      $redis->publish("mojo:redis:test" => "message $n")->execute;
      $n++;
      $redis->publish("mojo:redis:channel2" => "message $n")->execute;
    });
    Mojo::IOLoop->stop if @messages == 3;
  });
  $redis->on(pmessage => sub {
    shift;
    push @messages, [pmessage => @_];
    Mojo::IOLoop->stop if @messages == 3;
  });


  $tid = Mojo::IOLoop->recurring(0.02 => sub {
    Mojo::IOLoop->remove($tid) if ++$n == 2;
  });

  Mojo::IOLoop->start;

  is $err, '', 'no subscribe error';
  is_deeply $res, [ [qw( subscribe mojo:redis:test 1 )] ], 'subscribed to one channel';

  is_deeply(
    \@messages,
    [
      [ message => "message 1", "mojo:redis:test" ],
      [ message => "message 2", "mojo:redis:test" ],
      [ pmessage => "message 3", "mojo:redis:channel2", "mojo:redis:ch*" ],
    ],
    'got message events',
  );
}

done_testing;
