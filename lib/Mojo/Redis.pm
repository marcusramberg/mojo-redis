package Mojo::Redis;

our $VERSION = '0.9921';
use Mojo::Base 'Mojo::EventEmitter';

use Mojo::IOLoop;
use Mojo::Redis::Subscription;
use Mojo::URL;
use Scalar::Util ();
use Encode       ();
use Carp;
use constant DEBUG => $ENV{MOJO_REDIS_DEBUG} ? 1 : 0;

has server   => '127.0.0.1:6379';
has ioloop   => sub { Mojo::IOLoop->singleton };
has encoding => 'UTF-8';

has protocol_redis => sub {
  require Protocol::Redis;
  "Protocol::Redis";
};

has protocol => sub {
  my $self = shift;
  my $protocol = $self->protocol_redis->new(api => 1);

  $protocol or Carp::croak('protocol_redis implementation does not support APIv1');
  Scalar::Util::weaken($self);
  $protocol->on_message(
    sub {
      my ($parser, $command) = @_;
      $self->_return_command_data($command);
    }
  );

  $protocol;
};

sub connected { $_[0]->{connection} ? 1 : 0 }

sub timeout {
  return $_[0]->{timeout} || 0 unless @_ > 1;
  my($self, $t) = @_;
  my $id = $self->{connection};

  if(my $id = $self->{connection}) {
    if(my $stream = $self->ioloop->stream($id)) {
      $stream->timeout($t);
    }
  }

  $self->{timeout} = $t;
  $self;
}

for my $cmd (qw/
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
/) {
  eval(
    "sub $cmd {"
   .'my $self = shift;'
   ."\$self->execute($cmd => \@_) } 1;"
  ) or die $@;
}

sub DESTROY {
  $_[0]->ioloop or return; # may be undef during global destruction
  $_[0]->disconnect;
}

sub connect {
  my $self = shift;
  my $url = $self->_server_to_url;
  my($auth, $db_index);

  Scalar::Util::weaken $self;
  $auth = (split /:/, $url->userinfo || '')[1];
  $db_index = ($url->path =~ /(\d+)/)[0] || '';

  $self->disconnect; # drop old connection
  $self->{connecting} = 1;
  $self->{connection} = $self->ioloop->client(
    { address => $url->host,
      port    => $url->port || 6379,
    },
    sub {
      my ($loop, $error, $stream) = @_;

      if($error) {
          $self->_inform_queue(error => $error);
          return;
      }

      $stream->timeout($self->timeout);
      $stream->on(
        read => sub {
          my($stream, $chunk) = @_;
          if(DEBUG) {
            my $c2 = $chunk;
            $c2 =~ s/\r?\n/','/g;
            warn "REDIS[@{[$self->{connection}]}] >>> ['$c2']\n";
          }
          $self->protocol->parse($chunk);
        }
      );
      $stream->on(
        close => sub {
          $self or return;
          $self->_inform_queue;
          $self->emit('close');
        }
      );
      $stream->on(
        error => sub {
          $self or return; # $self may be undef during global destruction
          $self->_inform_queue(error => $_[1]);
        }
      );
      $stream->on(
        timeout => sub {
          $self or return; # $self may be undef during global destruction
          $self->_inform_queue(error => 'Timeout');
        }
      );

      my $mqueue = $self->{message_queue} ||= [];
      my $cqueue = $self->{cb_queue} ||= [];

      if($db_index =~ /^\d+/) { # need to be before defined $auth below
        unshift @$mqueue, [ SELECT => $db_index ];
        unshift @$cqueue, sub {}; # no error handling needed. got on(error => ...)
      }
      if(defined $auth) {
        unshift @$mqueue, [ AUTH => $auth ];
        unshift @$cqueue, sub {}; # no error handling needed. got on(error => ...)
      }

      delete $self->{connecting};
      $self->_send_next_message;
    }
  );

  return $self;
}

sub disconnect {
  my $self = shift;
  my $id = delete $self->{connection};

  delete $self->{connecting};

  $self->ioloop->remove($id) if $id and $self->ioloop;
  $self;
}

sub subscribe {
  my($self, @channels) = @_;
  $self->_subscribe_generic('subscribe', @channels);
}

sub psubscribe {
  my($self, @channels) = @_;
  $self->_subscribe_generic('psubscribe', @channels);
}

sub _subscribe_generic {
  my($self, $type, @channels) = @_;
  my $cb = ref $channels[-1] eq 'CODE' ? pop @channels : undef;
  my $n = 0;

  if(!$cb) {
    return Mojo::Redis::Subscription->new(
      channels => [@channels],
      server => $self->server,
      ioloop => $self->ioloop,
      encoding => $self->encoding,
      protocol_redis => $self->protocol_redis,
      timeout => $self->timeout,
      type => $type,
      connection => undef, # need to clear this when making a Subscription object from an active Redis object
    )->connect;
  }

  # need to attach new callback to the protocol object
  Scalar::Util::weaken $self;
  push @{ $self->{cb_queue} }, ($cb) x (@channels - 1);
  $self->execute(
    [ $type => @channels ],
    sub {
      shift; # we already got $self
      $self->$cb(@_);
      $self->{protocol} = $self->protocol_redis->new(api => 1);
      $self->{protocol} or Carp::croak(q/Protocol::Redis implementation doesn't support APIv1/);
      $self->{protocol}->on_message(
        sub {
          my ($parser, $message) = @_;
          my $data = $self->_reencode_message($message) or return;
          $self->$cb($data);
        }
      );
    }
  );
}

sub execute {
  my ($self, @commands) = @_;
  my($cb, $process);

  if (ref $commands[-1] eq 'CODE') {
    $cb = pop @commands;
  }
  if (ref $commands[0] ne 'ARRAY') {
    @commands = ([@commands]);
  }

  for my $cmd (@commands) {
    $cmd->[0] = uc $cmd->[0];
    if(ref $cmd->[-1] eq 'HASH') {
        splice @$cmd, -1, 1, map { $_ => $cmd->[-1]{$_} } keys %{ $cmd->[-1] };
    }
  }

  my $mqueue = $self->{message_queue} ||= [];
  my $cqueue = $self->{cb_queue}      ||= [];

  if($cb) {
    my @res;
    my $process = sub {
      if(my $command = shift @commands) {
        push @res, $command->[0] eq 'HGETALL' ? $_[1] ? { @{ $_[1] } } : undef : $_[1];
      }
      else {
        push @res, undef;
      }
      $_[0]->$cb(@res) unless @commands;
    };
    push @$cqueue, ($process) x int @commands;
  }
  else {
    push @$cqueue, (sub {}) x int @commands;
  }

  push @$mqueue, @commands;
  $self->connect unless $self->{connection};
  $self->_send_next_message;

  return $self;
}

sub _send_next_message {
  my ($self) = @_;

  $self->{connecting} and return;

  while (my $args = shift @{$self->{message_queue}}) {
    my $cmd_arg = [];

    foreach my $token (@$args) {
      $token = Encode::encode($self->encoding, $token)
        if $self->encoding;
      push @$cmd_arg, {type => '$', data => $token};
    }

    $self->_write({ type => '*', data => $cmd_arg }) or last;
  }
}

sub _reencode_message {
  my ($self, $message) = @_;
  my ($type, $data) = @{$message}{'type', 'data'};

  # Decode data
  if ($type ne '*' and $self->encoding and $data) {
    $data = Encode::decode($self->encoding, $data);
  }

  if ($type eq '-') {
    $self->emit_safe(error => $data);
    return;
  }
  elsif ($type ne '*') {
    return $data;
  }
  else {
    my $reencoded_data = [];
    foreach my $item (@$data) {
      my $message = $self->_reencode_message($item);
      push @$reencoded_data, $message;
    }
    return $reencoded_data;
  }
}

sub _return_command_data {
  my ($self, $message) = @_;
  my $data = $self->_reencode_message($message);
  my $cb = shift @{$self->{cb_queue}};

  eval {
    $self->$cb($data) if $cb;
    1;
  } or do {
    my $err = $@;
    $self->has_subscribers('error') ? $self->emit_safe(error => $err) : warn $err;
  };
}

sub _inform_queue {
  my ($self, @emit) = @_;
  my $cb_queue = delete $self->{cb_queue} || [];

  delete $self->{message_queue};
  $self->emit(@emit) if @emit;

  for my $cb (@$cb_queue) {
    eval {
      $self->$cb(undef) if $cb;
      1;
    } or do {
      my $err = $@;
      $self->has_subscribers('error') ? $self->emit_safe(error => $err) : warn $err;
    };
  }
}

sub _write {
  my($self, $what) = @_;
  my $ioloop = $self->ioloop;
  my($stream, $message);

  unless($stream = $ioloop->stream($self->{connection} || 0)) {
    $self->disconnect;
    return;
  }
  if(!$ioloop->is_running and $stream->is_readable) {
    $stream->close;
    $self->disconnect;
    return;
  }

  $message = $self->protocol->encode($what);
  $stream->write($message);

  if(DEBUG) {
    $message =~ s/\r?\n/','/g;
    warn "REDIS[@{[$self->{connection}]}] <<< ['$message']\n";
  }

  return 1;
}

sub _server_to_url {
  my $self = shift;
  my $url;

  if($self->server =~ m{^[^:]+:\d+$}) {
    $url = Mojo::URL->new('redis://' .$self->server);
  }
  else {
    $url = Mojo::URL->new($self->server);
  }

  # I have noooooo idea why this makes sense
  # https://github.com/kraih/mango/commit/5dc6d67bb84f32aa16bbd5967650366006672747
  Mojo::URL->new($url->scheme('http'));
}

1;
__END__

=head1 NAME

Mojo::Redis - Asynchronous Redis client for L<Mojolicious>.

=head1 SYNOPSIS

  use Mojo::Redis;

  my $redis = Mojo::Redis->new(server => '127.0.0.1:6379');

  # Execute some commands
  $redis->ping(
    sub {
      my ($redis, $res) = @_;
      if (defined $res) {
        print "Got result: ", $res, "\n";
      }
    }
  );

  # Work with keys
  # Ommitting the callback still makes it non-blocking and "error" events
  # will be called if something terrible goes wrong.
  $redis->set(key => 'value');

  $redis->get(
    key => sub {
      my ($redis, $res) = @_;
      print "Value of 'key' is $res\n";
    }
  );

  # Cleanup connection
  $redis->quit(sub { shift->ioloop->stop });

  # Start IOLoop (in case it is not started yet)
  $redis->ioloop->start;

Create new Mojo::IOLoop instance if you need to get blocked in a Mojolicious
application.

  use Mojolicious::Lite;
  use Mojo::Redis;

  get '/user' => sub {
    my $self = shift->render_later;
    my $uid = $self->session('uid');
    my $redis = Mojo::Redis->new;

    Mojo::IOLoop->delay(
      sub {
        my ($delay) = @_;
        $redis->hgetall("user:$uid", $delay->begin);
      },
      sub {
        my ($delay, $user) = @_;
        $self->render(json=>$user);
      },
    );
  };

  websocket '/messages' => sub {
    my $self = shift;
    my $tx = $self->tx;
    my $pub = Mojo::Redis->new;
    my $sub = $pub->subscribe('messages');

    # message from redis
    $sub->on(message => sub {
      my ($sub, $message, $channel) = @_; # $channel == messages
      $tx->send($message);
    });

    # message from websocket
    $self->on(message => sub {
      my ($self, $message) = @_;
      $pub->publish(messages => $message);
    });

    # need to clean up after websocket close
    $self->on(finish => sub {
      undef $pub;
      undef $sub;
      undef $tx;
    });
  };

  app->start;

=head1 DESCRIPTION

L<Mojo::Redis> is an asynchronous client to L<Redis|http://redis.io> for Mojo.

=head1 EVENTS

=head2 error

    $redis->on(error => sub{
        my($redis, $error) = @_;
        warn "[REDIS ERROR] $error\n";
    });

Emitted if error occurred. Called before commands callbacks.

=head2 close

    $redis->on(close => sub{
        my($redis) = @_;
        warn "[REDIS DISCONNECT]\n";
    });

Emitted when the connection to the server gets closed.

=head1 ATTRIBUTES

L<Mojo::Redis> implements the following attributes.

=head2 server

    my $server = $redis->server;
    $redis     = $redis->server('127.0.0.1:6379');
    $redis     = $redis->server('redis://anything:PASSWORD@127.0.0.1:6379/DB_INDEX');

C<Redis> server connection string, defaults to '127.0.0.1:6379'. The
latter can be used if you want L<Mojo::Redis> to automatically run L</auth>
with C<PASSWORD> and/or L</select> with C<DB_INDEX> on connect. Both AUTH
and DB_INDEX are optional.

=head2 ioloop

    my $ioloop = $redis->ioloop;
    $redis     = $redis->ioloop(Mojo::IOLoop->new);

Loop object to use for io operations, by default a L<Mojo::IOLoop> singleton
object will be used.

=head2 timeout

    my $timeout = $redis->timeout;
    $redis      = $redis->timeout(100);

Maximum amount of time in seconds a connection can be inactive before being
dropped, defaults to C<0> - meaning no timeout.

=head2 encoding

    my $encoding = $redis->encoding;
    $redis       = $redis->encoding('UTF-8');

Encoding used for stored data, defaults to C<UTF-8>.

=head2 protocol_redis

    use Protocol::Redis::XS;
    $redis->protocol_redis("Protocol::Redis::XS");

L<Protocol::Redis> implementation' constructor for parsing. By default
L<Protocol::Redis> will be used. Parser library must support
L<APIv1|Protocol::Redis/APIv1>.

Using L<Protocol::Redis::XS> instead of default choice can speedup parsing.

=head1 METHODS

L<Mojo::Redis> supports Redis' methods.

    $redis->set(key => 'value);
    $redis->get(key => sub { ... });

For more details take a look at C<execute> method.

Also L<Mojo::Redis> implements the following ones.

=head2 connect

    $redis = $redis->connect;

Connect to C<Redis> server.

=head2 execute

    $redis = $redis->execute("ping" => sub {
        my ($redis, $result) = @_;

        # Process result
    });
    $redis->execute(lrange => "test", 0, -1 => sub {...});
    $redis->execute(set => test => "test_ok");
    $redis->execute(
        [lrange => "test", 0, -1],
        [get => "test"],
        [hmset => foo => { one => 1, two => 2 }],
        sub {
            my($redis, $lrange, $get, $hmset) = @_;
            # ...
        },
    );

Execute specified command on C<Redis> server. If error occurred during
request $result will be set to undef, error string can be obtained with
the L</error> event.

=head1 REDIS METHODS

=head2 append

=head2 auth

See L</server> instead.

=head2 bgrewriteaof

=head2 bgsave

=head2 blpop

=head2 brpop

=head2 brpoplpush

=head2 config_get

=head2 config_resetstat

=head2 config_set

=head2 connected

=head2 dbsize

=head2 debug_object

=head2 debug_segfault

=head2 decr

=head2 decrby

=head2 del

=head2 discard

=head2 disconnect

=head2 echo

=head2 exec

=head2 exists

=head2 expire

=head2 expireat

=head2 flushall

=head2 flushdb

=head2 get

=head2 getbit

=head2 getrange

=head2 getset

=head2 hdel

=head2 hexists

=head2 hget

=head2 hgetall

=head2 hincrby

=head2 hkeys

=head2 hlen

=head2 hmget

=head2 hmset

=head2 hset

=head2 hsetnx

=head2 hvals

=head2 incr

=head2 incrby

=head2 info

=head2 keys

=head2 lastsave

=head2 lindex

=head2 linsert

=head2 llen

=head2 lpop

=head2 lpush

=head2 lpushx

=head2 lrange

=head2 lrem

=head2 lset

=head2 ltrim

=head2 mget

=head2 monitor

=head2 move

=head2 mset

=head2 msetnx

=head2 multi

=head2 persist

=head2 ping

=head2 protocol

=head2 psubscribe

Subscribes to channels matching the given patterns.

   # Subscribes to foo, foobar, foo.whaz, etc.
   my $psub = $redis->psubscribe('foo*');
   $psub->on(message => sub {
            my ($self, $msg, $channel, $pattern) = @_; # 'hi!', 'foo.roo', 'foo*'
          });

   $redis->publish('foo.roo' => 'hi!');

psubscribe has the same interface options and capabilities as L</subscribe>.

=head2 publish

=head2 quit

=head2 randomkey

=head2 rename

=head2 renamenx

=head2 rpop

=head2 rpoplpush

=head2 rpush

=head2 rpushx

=head2 sadd

=head2 save

=head2 scard

=head2 sdiff

=head2 sdiffstore

=head2 select

See L</server> instead.

=head2 set

=head2 setbit

=head2 setex

=head2 setnx

=head2 setrange

=head2 shutdown

=head2 sinter

=head2 sinterstore

=head2 sismember

=head2 slaveof

=head2 smembers

=head2 smove

=head2 sort

=head2 spop

=head2 srandmember

=head2 srem

=head2 strlen

=head2 subscribe

It's possible to subscribe in two ways:

   $self = $redis->subscribe('foo','bar' => sub {
     my ($redis, $data) = @_;
   });

The above code will overtake the current connection (if any) and put this
object into a pure subscribe mode.

   my $sub = $redis->subscribe('foo','bar');
   $sub->on(data => sub {
            my ($sub, $data) = @_;
          });

Opens up a new connection that subscribes to the given pubsub channels.
Returns an instance of L<Mojo::Redis::Subscription>. The existing C<$redis>
object can still be used to L</get> data as expected.

=head2 sunion

=head2 sunionstore

=head2 sync

=head2 ttl

=head2 type

=head2 unwatch

=head2 watch

=head2 zadd

=head2 zcard

=head2 zcount

=head2 zincrby

=head2 zinterstore

=head2 zrange

=head2 zrangebyscore

=head2 zrank

=head2 zrem

=head2 zremrangebyrank

=head2 zremrangebyscore

=head2 zrevrange

=head2 zrevrangebyscore

=head2 zrevrank

=head2 zscore

=head2 zunionstore

=head1 SEE ALSO

L<Protocol::Redis>, L<Mojolicious>, L<Mojo::IOLoop>

=head1 SUPPORT

You can contact the developers "marcus" and "batman" on IRC:
L<irc://irc.perl.org:6667/#mojo> (#mojo on irc.perl.org)

=head1 AUTHOR

Sergey Zasenko, C<undef@cpan.org>.

Forked from MojoX::Redis and updated to new IOLoop API by
Marcus Ramberg C<mramberg@cpan.org>
and Jan Henning Thorsen C<jhthorsen@cpan.org>.

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2010-2011, Sergey Zasenko
          (C) 2012, Marcus Ramberg

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=cut

