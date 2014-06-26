use Mojo::Base -base;
use Mojo::Redis2;
use Test::More;

plan skip_all => 'Missing MOJO_REDIS_URL=redis://localhost/14' unless $ENV{MOJO_REDIS_URL};

my $redis = Mojo::Redis2->new;
my @res;

is $redis->url, $ENV{MOJO_REDIS_URL}, 'url() is set';
isa_ok $redis->protocol, $ENV{MOJO_REDIS_PROTOCOL};

@res = eval { $redis->execute };
is_deeply \@res, [], 'no commands to execute' or diag join '|', @res;

is $redis->set('mojo:redis2:scalar' => 42), $redis, 'SET mojo:redis2:test:get 42';
is $redis->get('mojo:redis2:scalar'), $redis, 'GET mojo:redis2:test:get';

@res = eval { $redis->execute };
is_deeply \@res, ['OK', '42'], 'got set+get response' or diag join '|', @res;

Mojo::IOLoop->delay(
  sub {
    my ($delay) = @_;
    $redis->ping->get("mojo:redis2:scalar", $delay->begin);
  },
  sub {
    my ($delay, $err, $res) = @_;
    @res = @$res;
    Mojo::IOLoop->stop;
  },
);
Mojo::IOLoop->start;

is_deeply \@res, ['PONG', '42'], 'got ping+get response' or diag join '|', @res;

is_deeply [$redis->del('mojo:redis2:scalar')->execute], ['1'], 'DEL mojo:redis2:test:get';

done_testing;
