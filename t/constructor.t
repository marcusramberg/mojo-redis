use Mojo::Base -base;
use Mojo::Redis2;
use Test::More;

plan skip_all => 'Missing MOJO_REDIS_URL=redis://localhost/14' unless $ENV{MOJO_REDIS_URL};

my $redis = Mojo::Redis2->new;
my @res;

is $redis->url, $ENV{MOJO_REDIS_URL}, 'url() is set';
isa_ok $redis->protocol, $ENV{MOJO_REDIS_PROTOCOL};

is_deeply [$redis->execute], [], 'no commands to execute' or diag join '|', @res;

done_testing;
