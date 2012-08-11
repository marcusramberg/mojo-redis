#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Mojo::IOLoop;
use utf8;

plan skip_all => 'Setup $REDIS_SERVER'
  unless $ENV{REDIS_SERVER};

plan tests => 5;

use_ok 'Mojo::Redis';

my $redis =
  new_ok 'Mojo::Redis' => [server => $ENV{REDIS_SERVER}, timeout => 5];

my $errors = 0;
$redis->on_error(sub { $errors++ });

my $cb=0;
use Data::Dumper;
$redis->subscribe(
    'foo','bar' => sub {
        my ($redis,$res)=@_;
        warn('Got ' .Data::Dumper::Dumper($res));
        $cb++;
        if($cb==1) {
            is_deeply( $res, ['subscribe', 'foo', 1], "first" );
        }
        elsif($cb==2) {
            is_deeply( $res, ['subscribe', 'bar', 2], "second" );
        }
        elsif($cb==3) {
            is_deeply( $res, ['message', 'foo','shoo'], "third");
             $redis->stop;
        }
    }
);

$redis->execute('publish',['foo', 'shoo']);
$redis->publish('bar', 'once mo')->start;

