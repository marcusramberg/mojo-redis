use Test::More;
use File::Find;

if(($ENV{HARNESS_PERL_SWITCHES} || '') =~ /Devel::Cover/) {
  plan skip_all => 'HARNESS_PERL_SWITCHES =~ /Devel::Cover/';
}
if(!eval 'use Test::Pod; 1') {
  *Test::Pod::pod_file_ok = sub { SKIP: { skip "pod_file_ok(@_) (Test::Pod is required)", 1 } };
}
if(!eval 'use Test::Pod::Coverage; 1') {
  *Test::Pod::Coverage::pod_coverage_ok = sub { SKIP: { skip "pod_coverage_ok(@_) (Test::Pod::Coverage is required)", 1 } };
}

find(
  {
    wanted => sub { /\.pm$/ and push @files, $File::Find::name },
    no_chdir => 1
  },
  -e 'blib' ? 'blib' : 'lib',
);

plan tests => @files * 3;

for my $file (@files) {
  my $module = $file; $module =~ s,\.pm$,,; $module =~ s,.*/?lib/,,; $module =~ s,/,::,g;
  ok eval "use $module; 1", "use $module" or diag $@;
  Test::Pod::pod_file_ok($file);
  Test::Pod::Coverage::pod_coverage_ok($module, {
    also_private => [qw(
      append auth bgrewriteaof bgsave blpop brpop brpoplpush config_get config_set
      config_resetstat dbsize debug_object debug_segfault decr decrby del discard
      echo exec exists expire expireat flushall flushdb get getbit getrange getset
      hdel hexists hget hgetall hincrby hkeys hlen hmget hmset hset hsetnx hvals
      incr incrby info keys lastsave lindex linsert llen lpop lpush lpushx lrange
      lrem lset ltrim mget monitor move mset msetnx multi persist ping
      publish quit randomkey rename renamenx rpop rpoplpush rpush
      rpushx sadd save scard sdiff sdiffstore select set setbit setex setnx
      setrange shutdown sinter sinterstore sismember slaveof smembers smove sort
      spop srandmember srem strlen sunion sunionstore sync ttl type
      unwatch watch zadd zcard zcount zincrby zinterstore zrange
      zrangebyscore zrank zrem zremrangebyrank zremrangebyscore zrevrange
      zrevrangebyscore zrevrank zscore zunionstore
    )],
  });
}
