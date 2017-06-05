use Mojo::Base -strict;
use Test::More;
use Mojo::Redis;

my $redis = Mojo::Redis->new;

like $redis->protocol_class, qr{Protocol::Redis},      'connection_class';
is $redis->max_connections,  5,                        'max_connections';
is $redis->url,              'redis://localhost:6379', 'url';

$redis = Mojo::Redis->new('redis://redis.localhost');
is $redis->url, 'redis://redis.localhost', 'custom url';

$redis = Mojo::Redis->new(Mojo::URL->new('redis://redis.example.com'));
is $redis->url, 'redis://redis.example.com', 'custom url object';

done_testing;
