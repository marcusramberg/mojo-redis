use Mojo::Base -strict;
use Mojo::IOLoop;
use Test::More;
use utf8;

plan skip_all => 'Setup $REDIS_SERVER' unless $ENV{REDIS_SERVER};
plan tests => 3;

use_ok 'Mojo::Redis';

my $redis = Mojo::Redis->new(server => $ENV{REDIS_SERVER}, timeout => 0.1);
my $sub = $redis->subscribe('anything');

$sub->on(error => sub {
    is $_[1], 'Timeout', 'got timeout';
    Mojo::IOLoop->stop;
});
$sub->on(close => sub {
    diag 'close';
});
$sub->on(message => sub {
    diag join ', ', @_;
});

Mojo::IOLoop->start;

$redis->timeout(0);
is $redis->timeout, 0, 'timeout is 0';
