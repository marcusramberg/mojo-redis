#!/usr/bin/end perl

use strict;
use warnings;

use Test::More;
use Mojo::IOLoop;

plan skip_all => 'Setup $REDIS_SERVER'
    unless $ENV{REDIS_SERVER};

plan tests => 6;

use_ok 'MojoX::Redis';

my $redis = new_ok 'MojoX::Redis' => [ server => $ENV{REDIS_SERVER} ];

$redis->execute( ping  =>  sub { is_deeply shift, ['PONG'], "Line result test" })
    ->execute( set   => [test => 'test_ok'], sub { is_deeply shift, ['OK'], "Another line result" })
    ->execute( get   => 'test', sub { is_deeply shift, ['test_ok'], "Bulk result"})
    ->execute( del   => 'test' )
    ->execute( rpush => [test => 'test1'] )
    ->execute( rpush => [test => 'test2'] )
    ->execute( lrange=> ['test', 0, -1], sub {
            is_deeply shift, ["test1", "test2"], "Multy-bulk result";
            Mojo::IOLoop->singleton->stop;
        }
    );

Mojo::IOLoop->singleton->start;

