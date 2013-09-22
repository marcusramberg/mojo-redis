#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Mojo::Redis;

BEGIN {
  eval q{use Test::LeakTrace};
  plan skip_all => "Test::LeakTrace required" if $@;
}

plan skip_all => 'Setup $REDIS_SERVER'
  unless $ENV{REDIS_SERVER};

plan tests => 5;

no_leaks_ok {
  redis()->ping(\&cb_ioloop_stop)->ioloop->start;
}
"ping";

no_leaks_ok {
  redis()->execute("strange_command", \&cb_ioloop_stop)->ioloop->start;
}
"error";

no_leaks_ok {
  redis()->set(test => 'test_ok', \&cb_ioloop_stop)->ioloop->start;
}
"set";

no_leaks_ok {
  redis()->get(test => \&cb_ioloop_stop)->ioloop->start;
}
"get";

no_leaks_ok {
  my $sub = redis()->subscribe('test:random:sub:key');
  $sub->on(data => \&cb_ioloop_stop);
  $sub->ioloop->start;
}
"subscribe";

sub cb_ioloop_stop {
  shift->ioloop->stop;
}

sub redis {
  my $redis = Mojo::Redis->new(server => $ENV{REDIS_SERVER}, timeout => 5);
  $redis->on(error => sub {});
  $redis->select(14);
  $redis;
}

