#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Mojo::IOLoop;

plan skip_all => 'Setup $REDIS_SERVER=127.0.0.1:6379' unless $ENV{REDIS_SERVER};
use_ok 'Mojo::Redis';

my $server = "redis://anything:INVALIDKEY\@$ENV{REDIS_SERVER}/123";
my $redis = Mojo::Redis->new(server => $server, timeout => 5);
my($sub, @errors);

$redis->on(error => sub { push @errors, $_[1] });
$redis->execute(ping => sub {});
$sub = $redis->subscribe('foo');
$sub->on(error => sub { push @errors, $_[1] });
$redis->quit(sub { shift->ioloop->stop; })->ioloop->start;

like $errors[0], qr{^ERR.*AUTH}, 'could not login to subscribe' or diag $errors[0];
like $errors[1], qr{^ERR.*DB}, 'could not select db 123 on subscribe' or diag $errors[1];
like $errors[2], qr{^ERR.*AUTH}, 'could not login to redis' or diag $errors[2];
like $errors[3], qr{^ERR.*DB}, 'could not select db 123 on redis' or diag $errors[3];

done_testing;
