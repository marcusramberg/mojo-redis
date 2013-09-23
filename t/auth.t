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
$redis->quit(sub { shift->ioloop->stop })->ioloop->start;

like $errors[0], qr{^ERR.*AUTH}, 'could not login to redis';
like $errors[1], qr{^ERR.*DB}, 'could not select db 123 on redis';

@errors = ();
$sub = $redis->subscribe('foo');
$sub->on(error => sub { push @errors, $_[1]; shift->ioloop->stop });
$sub->ioloop->start;

like $errors[0], qr{^ERR.*AUTH}, 'could not login to subscribe';
like $errors[1], qr{^ERR.*DB}, 'could not select db 123 on subscribe';

done_testing;
