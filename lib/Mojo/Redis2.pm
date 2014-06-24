package Mojo::Redis2;

=head1 NAME

Mojo::Redis2 - Pure-Perl non-blocking I/O Redis driver

=head1 VERSION

0.01

=head1 DESCRIPTION

L<Mojo::Redis2> is a pure-Perl non-blocking I/O L<Redis|http://redis.io>
driver for the L<Mojolicious> real-time framework.

Features:

=over 4

=item * Blocking support

L<Mojo::Redis2> support blocking methods. NOTE: Calling non-blocking and
blocking methods are supported on the same object, but might create a new
connection to the server.

=item * Error handling that makes sense

L<Mojo::Redis> was unable to report back errors that was bound to an operation.
L<Mojo::Redis2> on the other hand always make sure each callback receive an
error message on error.

=item * One object for different operations

L<Mojo::Redis> had only one connection, so it could not do more than on
blocking operation on the server side at the time (such as BLPOP,
SUBSCRIBE, ...). This object creates new connections pr. blocking operation
which makes it easier to avoid "blocking" bugs.

=item * Transaction support

Transactions will done in a new L<Mojo::Redis2> object that also act as a
guard: The transaction will not be run if the guard goes out of scope.

=back

=head1 SYNOPSIS

=head2 Blocking

  use Mojo::Redis2;
  my $redis = Mojo::Redis2->new;

  # Will die() as soon as possible on error.
  # On success: @res = ("OK", "42", "OK");
  @res = $redis->set(foo => "42")->get("foo")->set(bar => 123)->execute;

  # Might die() too late, because of pipelined() will cause data to be sent to
  # the redis server without waiting for response.
  # On success: @res = ("OK", "42", "OK");
  @res = $redis->pipelined->set(foo => "42")->get("foo")->set(bar => 123)->execute;

=head2 Non-blocking

  Mojo::IOLoop->delay(
    sub {
      my ($delay) = @_;
      # Will not run "GET foo" unless ping() was successful
      # Use pipelined() before ping() if you want all commands to run even
      # if one operation fail.
      $redis->ping->get("foo")->execute($delay->begin);
    },
    sub {
      my ($delay, $err, $res) = @_;
      # On error: $err is set to a string
      # NOTE: $err might be set on partial success, when using pipelined()
      # On success: $res = [ "PONG", "42" ];
    },
  );

=head2 Pub/sub

L<Mojo::Redis2> can L</subscribe> and re-use the same object to C<publish> or
run other Redis commands, since it can keep track of multiple connections to
the same Redis server.

  $id = $self->subscribe("some:channel" => sub {
    my ($self, $err, $message, $channel) = @_;

    $self->incr("messsages_from:some:channel");
    $self->unsubscribe($id); # stop subscription
  });

L</unsubscribe> will be automatically called if C<$err> is present.

=cut

use Mojo::Base 'Mojo::EventEmitter';
use Mojo::URL;
use Carp ();
use constant DEBUG => $ENV{MOJO_REDIS_DEBUG} || 0;

our $VERSION = '0.01';

my $PROTOCOL_CLASS = do {
  my $class = $ENV{MOJO_REDIS_PROTOCOL} || eval "require Protocol::Redis::XS; 'Protocol::Redis::XS'" || 'Protocol::Redis';
  eval "require $class; 1" or die $@;
  $class;
};

my %REDIS_METHODS = map { ($_, 1) } (
  'append',   'blpop',           'brpop',            'brpoplpush',  'decr',             'decrby',
  'del',      'exists',          'expire',           'expireat',    'get',              'getbit',
  'getrange', 'getset',          'hdel',             'hexists',     'hget',             'hgetall',
  'hincrby',  'hkeys',           'hlen',             'hmget',       'hmset',            'hset',
  'hsetnx',   'hvals',           'incr',             'incrby',      'keys',             'lindex',
  'linsert',  'llen',            'lpop',             'lpush',       'lpushx',           'lrange',
  'lrem',     'lset',            'ltrim',            'mget',        'move',             'mset',
  'msetnx',   'persist',         'ping',             'publish',     'randomkey',        'rename',
  'renamenx', 'rpop',            'rpoplpush',        'rpush',       'rpushx',           'sadd',
  'scard',    'sdiff',           'sdiffstore',       'set',         'setbit',           'setex',
  'setnx',    'setrange',        'sinter',           'sinterstore', 'sismember',        'smembers',
  'smove',    'sort',            'spop',             'srandmember', 'srem',             'strlen',
  'sunion',   'sunionstore',     'ttl',              'type',        'zadd',             'zcard',
  'zcount',   'zincrby',         'zinterstore',      'zrange',      'zrangebyscore',    'zrank',
  'zrem',     'zremrangebyrank', 'zremrangebyscore', 'zrevrange',   'zrevrangebyscore', 'zrevrank',
  'zscore',   'zunionstore',
);

=head1 EVENTS

=head2 close

  $self->on(close => sub { my ($self, $id) = @_; });

Emitted when a connection close.

=head2 connection

  $self->on(connection => sub { my ($self, $id) = @_; });

Emitted when a new connection has been established.

=head2 error

  $self->on(error => sub { my ($self, $err) = @_; ... });

Emitted if an error occurs that can't be associated with an operation.

=head1 ATTRIBUTES

=head2 protocol

  $obj = $self->protocol;
  $self = $self->protocol($obj);

Holds an object used to parse/generate Redis messages.
Defaults to L<Protocol::Redis::XS> or L<Protocol::Redis>.

L<Protocol::Redis::XS> need to be installed manually.

=cut

has protocol => sub { $PROTOCOL_CLASS->new(api => 1); };

=head2 url

  $self = $self->url("redis://x:$auth_key\@$server:$port/$database_index");
  $url = $self->url;

Holds a L<Mojo::URL> object with the location to the Redis server. Default
is C<redis://localhost:6379>.

=cut

sub url {
  return $_[0]->{url} ||= Mojo::URL->new('redis://localhost:6379') if @_ == 1;
  $_[0]->{url} = Mojo::URL->new($_[1]);
  $_[0];
}

=head1 METHODS

=head2 execute

  @res = $self->execute;
  $self = $self->execute(sub { my ($self, @res) = @_; ... });

Will send the L<prepared|/prepare> commands to the Redis server.

=head2 pipelined

  $self = $self->pipelined;

Will mark L<prepared|/prepare> operations to be sent to the server
as soon as possible.

=cut

sub pipelined {
  $_[0]->{pipelined} = $_[1] // 1;
  $_[0];
}

=head2 prepare

  $self = $self->prepare($redis_method => @redis_args);

Used to prepare commands for L</execute>. Example:

  $self->prepare(GET => "foo");

There are also shortcuts for most of the C<$redis_method>. Example:

  $self->get("foo");

List of Redis methods available on C<$self>:

append, blpop, brpop, brpoplpush, decr, decrby,
del, exists, expire, expireat, get, getbit,
getrange, getset, hdel, hexists, hget, hgetall,
hincrby, hkeys, hlen, hmget, hmset, hset,
hsetnx, hvals, incr, incrby, keys, lindex,
linsert, llen, lpop, lpush, lpushx, lrange,
lrem, lset, ltrim, mget, move, mset,
msetnx, persist, ping, publish, randomkey, rename,
renamenx, rpop, rpoplpush, rpush, rpushx, sadd,
scard, sdiff, sdiffstore, set, setbit, setex,
setnx, setrange, sinter, sinterstore, sismember, smembers,
smove, sort, spop, srandmember, srem, strlen,
sunion, sunionstore, ttl, type, zadd, zcard,
zcount, zincrby, zinterstore, zrange, zrangebyscore, zrank,
zrem, zremrangebyrank, zremrangebyscore, zrevrange, zrevrangebyscore, zrevrank,
zscore and zunionstore.

=head2 psubscribe

Same as L</subscribe>, but C<@channels> is a list of patterns instead of exact
channel names. See L<http://redis.io/commands/psubscribe> for details.

=head2 subscribe

  $id = $self->subscribe(
          @channels,
          \%args,
          sub {
            my ($self, $err, $message, $channel) = @_;
          },
        );

Used to subscribe to specified channels. See L<http://redis.io/topics/pubsub>
for details. This method is only useful in non-blocking context.

=head2 unsubscribe

  $self->unsubscribe($id);
  $self->unsubscribe($event_name);
  $self->unsubscribe($event_name => $cb);

Same as L<Mojo::EventEmitter/unsubscribe>, but can also close down a
L</subscribe> connection based on an C<$id>.

=cut

sub AUTOLOAD {
  my $self = shift;
  my ($package, $method) = split /::(\w+)$/, our $AUTOLOAD;

  unless ($REDIS_METHODS{$method}) {
    Carp::croak(qq{Can't locate object method "$method" via package "$package"});
  }

  eval "sub $method { shift->prepare($method => \@_); }; 1" or die $@;
  $self->prepare($method => @_);
}

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014, Jan Henning Thorsen

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut

1;
