#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Mojo::IOLoop;
use utf8;

plan skip_all => 'Setup $REDIS_SERVER'
  unless $ENV{REDIS_SERVER};

plan tests => 22;

use_ok 'Mojo::Redis';

my $redis = new_ok 'Mojo::Redis' => [server => $ENV{REDIS_SERVER}, timeout => 5];

my @errors;
$redis->on(error => sub { push @errors, $_[1] });
$redis->select(14);


$redis->execute(
    ping => sub {
        is $_[1], 'PONG', "Line result test";
    }
);

$redis->once(error => sub {
    is $_[1], q|ERR unknown command 'QWE'|,
});

$redis->execute(
    qwe => sub {
        is $_[1], undef, 'Uknown command result';
        is int(@errors), 1, 'on_error works';
    }
);

$redis->execute(
    set => qw/test test_ok/,
    sub { is $_[1], 'OK', "Another line result"; }
);

$redis->execute(get => 'test',
    sub { is $_[1], 'test_ok', "Bulk result"; }
);

$redis->execute(del => 'test')->execute([rpush => test => 'test1'])
  ->execute(rpush => test => 'test2')->execute(
    [lrange => qw/test 0 -1/],
    sub {
        is_deeply $_[1], ["test1", "test2"], "Multi-bulk result";
    }
  );

$redis->execute(set => 'test','привет')->execute(
    get => 'test',
    sub {ok utf8::is_utf8($_[1]), "Unicode test" }
);

$redis->execute([del => 'test']);
$redis->execute(hmset => 'test', 'key', 'привет');
$redis->execute(hmget => qw/test key/,
    sub {
         ok utf8::is_utf8($_[1]->[0]), "Unicode test on multibulk reply";
    }
);

$redis->execute(del => 'test')->execute(
    [get => 'test'],
    sub { is $_[1], undef, "Bulk nil return check" }
);

$redis->execute(lrange => qw/test 0 -1/,
    sub {
        is_deeply $_[1], [], "Multi-bulk nil return check";
    }
);

$redis->execute(
    ping => sub {
        is $_[1], 'PONG', "Last check";
    }
);

$redis->del('test') for 1..5;
$redis->execute(set => test => 1) for 1..5;
$redis->execute([set => test => 1], [set => test => 1]) for 1..3;
$redis->set(test => 'ok')->get(
    test => sub {
        is $_[1], 'ok', "Fast command check";
    }
);

$redis->execute(
    [del => "test"],
    [rpush => "test", 123],
    [lrange => "test", 0, 1],
    [hmset => foo => { one => 1, two => 2 }],
    [hgetall => 'foo'],
    sub {
        my($redis, $del, $rpush, $lrange, $hmset, $hgetall) = @_;
        is $del, 1, 'got del result';
        is $rpush, '1', 'got rpush result';
        is_deeply $lrange, [123], 'got lrange result';
        is $hmset, 'OK', 'got hmset result';
        is_deeply $hgetall, { one => 1, two => 2 }, 'got hgetall result as hash ref';
    },
);

$redis->hgetall(foo => sub {
    is_deeply $_[1], { one => 1, two => 2 }, 'hgetall() result as hash ref';
});

$redis->quit(sub { shift->ioloop->stop; })->ioloop->start;
is int(@errors), 1, 'no more errors detected' or diag join '|', @errors;
