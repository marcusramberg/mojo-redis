use utf8;
use Mojo::Base -base;
use Mojo::Redis2;
use Test::More;

plan skip_all => 'Missing MOJO_REDIS_URL=redis://localhost/14' unless $ENV{MOJO_REDIS_URL};

my $redis = Mojo::Redis2->new;
my @res;

is $redis->set('mojo:redis2:utf8' => 'å-hoi'), $redis, 'SET mojo:redis2:utf8';
is $redis->get('mojo:redis2:utf8'), $redis, 'GET mojo:redis2:test:get';

@res = eval { $redis->execute };
is_deeply \@res, ['OK', 'å-hoi'], 'got set+get utf-8 response' or diag join '|', @res;
is_deeply [$redis->del('mojo:redis2:utf8')->execute], ['1'], 'DEL mojo:redis2:test:get';

done_testing;
