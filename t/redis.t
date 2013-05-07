#!/usr/bin/env perl

# Becouse of two async applications working together this tests look ugly
# if you want to examine Mojo::Redis API take a look at t/redis_live.t

use strict;
use warnings;
use Test::More tests => 13;
use Mojo::IOLoop;

use_ok 'Mojo::Redis';

my $port = Mojo::IOLoop->generate_port;

my ($sbuffer1, $sbuffer2, $sbuffer3);
my ($r, $r1, $r2, $r4);
my $curr_stream;

$r4 = 'wrong result';

my $server = Mojo::IOLoop->server(
    {port => $port},
    sub {
        my ($loop, $stream) = @_;
        $curr_stream = $stream;
        $stream->once(
            read => sub {
                my ($stream, $chunk) = @_;
                $sbuffer1 = $chunk;
                $stream->write("\$2\r\nok\r\n");
        });
    });

my $redis =
  new_ok 'Mojo::Redis' => [server => "127.0.0.1:$port", timeout => 1];
Mojo::IOLoop->timer(5 => sub { $redis->ioloop->stop }); #security valve

can_ok($redis, qw/
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
  zrevrangebyscore zrevrank zscore zunionstore/);


$redis->execute(
    get => 'test',
    sub {
        my ($redis, $result) = @_;
        $r = $result;
        &test2;
    }
)->ioloop->start;


is $sbuffer1, "*2\r\n\$3\r\nGET\r\n\$4\r\ntest\r\n", 'input command';
is $r, 'ok', 'result';

is $sbuffer2,
  "*2\r\n\$3\r\nGET\r\n\$5\r\ntest1\r\n*2\r\n\$3\r\nGET\r\n\$5\r\ntest2\r\n",
  'input commands';
is $r1, 'ok1', 'first command';
is $r2, 'ok2', 'second command';

is $sbuffer3, "*3\r\n\$3\r\nSET\r\n\$3\r\nkey\r\n\$5\r\nvalue\r\n",
  'fast command';

is $r4, undef, 'error result';


$redis = Mojo::Redis->new(server => 'redis://redis.server:1234/14');
is $redis->_server_to_url->host, 'redis.server', 'got host';
is $redis->_server_to_url->port, '1234', 'got port';
is +($redis->_server_to_url->path =~ /(\d+)/)[0], '14', 'got db index';

# Multiple pipelined commands
sub test2 {
    $curr_stream->once(
        read => sub {
            my ($stream, $chunk) = @_;
            $sbuffer2 .= $chunk;

            # Wait both commands to come
            if ($sbuffer2 =~ m{test2}) {
                $stream->on(read => sub { });

                # Half of first command
                $stream->write(
                    "\$3\r\nok",
                    sub {
                        Mojo::IOLoop->timer(
                            0.1 => sub {
                                my ($self) = @_;

                                # Another half with first half of second
                                $stream->write(
                                    "1\r\n\$3",
                                    sub {
                                        Mojo::IOLoop->timer(
                                            0.1 => sub {
                                                my ($self) = @_;

                                                # Done
                                                $stream->write(
                                                    "\r\nok2\r\n");
                                            }
                                        );
                                    }
                                );
                            }
                        );
                    }
                );
            }
        }
    );
    $redis->execute(
        get => 'test1',
        sub {
            my ($redis, $result) = @_;
            $r1 = $result;
        }
      )->execute(
        get => 'test2',
        sub {
            my ($redis, $result) = @_;
            $r2 = $result;
            &check3;
        }
      );
}

sub check3 {
    $curr_stream->once(
        read => sub {
            my ($stream, $chunk) = @_;
            $sbuffer3 = $chunk;

            &check4;
        }
    );

    $redis->set(key => 'value', sub { });
}

sub check4 {
    $curr_stream->once(
        read => sub {
            my ($stream, $chunk) = @_;
            Mojo::IOLoop->remove($server);
       }
    );

    $redis->execute(
        get => 'test',
        sub {
            my ($redis, $result) = @_;
            $r4          = $result;
            Mojo::IOLoop->stop;

        }
    );

}
