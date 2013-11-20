use Mojo::Base -strict;
use Test::More;

use_ok 'Mojo::Redis';
new_ok 'Mojo::Redis' => [ server => '127.0.0.1:12345', timeout => 1 ];

is Mojo::Redis->new->timeout, 0, 'default timeout is 0';

can_ok(
  'Mojo::Redis',
  qw(
    append auth bgrewriteaof bgsave blpop brpop brpoplpush config_get config_set
    config_resetstat dbsize debug_object debug_segfault decr decrby del discard
    echo exec exists expire expireat flushall flushdb get getbit getrange getset
    hdel hexists hget hgetall hincrby hkeys hlen hmget hmset hset hsetnx hvals
    incr incrby info keys lastsave lindex linsert llen lpop lpush lpushx lrange
    lrem lset ltrim mget monitor move mset msetnx multi persist ping
    publish quit randomkey rename renamenx rpop rpoplpush rpush
    rpushx sadd save scard sdiff sdiffstore select set setbit setex setnx
    setrange shutdown sinter sinterstore sismember slaveof smembers smove sort
    spop srandmember srem strlen subscribe sunion sunionstore sync ttl type
    unsubscribe unwatch watch zadd zcard zcount zincrby zinterstore zrange
    zrangebyscore zrank zrem zremrangebyrank zremrangebyscore zrevrange
    zrevrangebyscore zrevrank zscore zunionstore
  ),
);

{
  my $redis = Mojo::Redis->new(server => 'redis://redis.server:1234/14');
  is $redis->_server_to_url->host, 'redis.server', 'got host';
  is $redis->_server_to_url->port, '1234', 'got port';
  is +($redis->_server_to_url->path =~ /(\d+)/)[0], '14', 'got db index';
}

done_testing;
