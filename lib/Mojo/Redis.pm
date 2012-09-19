package Mojo::Redis;

our $VERSION = 0.9;
use Mojo::Base 'Mojo::EventEmitter';

use Mojo::IOLoop;
use Scalar::Util ();
use Encode       ();
require Carp;

has server   => '127.0.0.1:6379';
has ioloop   => sub { Mojo::IOLoop->singleton };
has timeout  => 10;
has encoding => 'UTF-8';

has protocol_redis => sub {
  require Protocol::Redis;
  "Protocol::Redis";
};

has protocol => sub {
  my $self = shift;

  my $protocol = $self->protocol_redis->new(api => 1);
  $protocol->on_message(
    sub {
      my ($parser, $command) = @_;
      $self->_return_command_data($command);
    }
  );

  Carp::croak(q/Protocol::Redis implementation doesn't support APIv1/)
    unless $protocol;

  $protocol;
};

for my $cmd (qw/
  append auth bgrewriteaof bgsave blpop brpop brpoplpush config_get config_set
  config_resetstat dbsize debug_object debug_segfault decr decrby del discard
  echo exec exists expire expireat flushall flushdb get getbit getrange getset
  hdel hexists hget hgetall hincrby hkeys hlen hmget hmset hset hsetnx hvals
  incr incrby info keys lastsave lindex linsert llen lpop lpush lpushx lrange
  lrem lset ltrim mget monitor move mset msetnx multi persist ping psubscribe
  publish punsubscribe quit randomkey rename renamenx rpop rpoplpush rpush
  rpushx sadd save scard sdiff sdiffstore select set setbit setex setnx
  setrange shutdown sinter sinterstore sismember slaveof smembers smove sort
  spop srandmember srem strlen sunion sunionstore sync ttl type
  unsubscribe unwatch watch zadd zcard zcount zincrby zinterstore zrange
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
  my $self = shift;

  # Loop
  return unless my $loop = $self->ioloop;

  # Cleanup connection
  $loop->remove($self->{_connection})
    if $self->{_connection};
}


sub connect {
  my $self = shift;

  # drop old connection
  if ($self->connected) {
    $self->ioloop->remove($self->{_connection});
  }

  $self->server =~ m{^([^:]+)(:(\d+))?};
  my $address = $1;
  my $port = $3 || 6379;

  Scalar::Util::weaken $self;

  # connect
  $self->{_connecting} = 1;
  $self->{_connection} = $self->ioloop->client(
    { address => $address,
      port    => $port
    },
    sub {
      my ($loop, $error, $stream) = @_;

      if($error) {
          $self->_inform_queue;
          $self->emit_safe(error => $error);
          return;
      }

      delete $self->{_connecting};
      $stream->timeout($self->timeout);
      $self->_send_next_message;

      $stream->on(
        read => sub {
          my ($stream, $chunk) = @_;
          $self->protocol->parse($chunk);
        }
      );
      $stream->on(
        close => sub {
          my $str = shift;
          $self->_inform_queue;

          delete $self->{_message_queue};
          delete $self->{_connecting};
          delete $self->{_connection};
        }
      );
      $stream->on(
        error => sub {
          my ($str, $error) = @_;
          $self->_inform_queue;
          $self->emit_safe(error => $error);

          $self->emit_safe(error => $error);
          $self->ioloop->remove($self->{_connection});
        }
      );
    }
  );

  return $self;
}

sub disconnect {
  my $self = shift;

  # drop old connection
  if ($self->connected) {
    $self->ioloop->remove($self->{_connection});
  }
}

sub connected {
  my $self = shift;

  return $self->{_connection};
}

sub subscribe {
  my $cb = pop @_;
  my ($self, @channels) = @_;
  my $protocol = $self->protocol_redis->new(api => 1);
  $protocol->on_message(
    sub {
      my ($parser, $message) = @_;
      my $data = $self->_reencode_message($message);
      $cb->($self, $data) if $cb;
    }
  );

  $self->server =~ m{^([^:]+)(:(\d+))?};
  my $address = $1;
  my $port = $3 || 6379;

  my $id;
  $id = $self->ioloop->client(
    { address => $address,
      port    => $port
    },
    sub {
      my ($loop, $error, $stream) = @_;

      if($error) {
          $self->{error} = $error;
          $self->emit(error => $error);
          return;
      }

      $stream->timeout($self->timeout);

      $stream->on(
        read => sub {
          my ($stream, $chunk) = @_;
          $protocol->parse($chunk);
        }
      );
      $stream->on(
        close => sub {
          my $str = shift;
          warn "subscription disconnected";
        }
      );
      $stream->on(
        error => sub {
          my ($str, $error) = @_;
          $self->emit(error => $error);
          $self->ioloop->remove($id);
        }
      );
      my $cmd_arg = [];
      my $cmd     = {type => '*', data => $cmd_arg};
      my @args    = ('subscribe', @channels);
      foreach my $token (@args) {
        $token = Encode::encode($self->encoding, $token)
          if $self->encoding;
        push @$cmd_arg, {type => '$', data => $token};
      }
      my $message = $self->protocol->encode($cmd);

      $stream->write($message);
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

  my $mqueue = $self->{_message_queue} ||= [];
  my $cqueue = $self->{_cb_queue}      ||= [];

  if($cb) {
    my @res;
    my $process = sub {
      my $command = shift @commands;
      push @res, $command->[0] eq 'HGETALL' ? { @{ $_[1] } } : $_[1];
      $_[0]->$cb(@res) unless @commands;
    };
    push @$cqueue, ($process) x int @commands;
  }
  else {
    push @$cqueue, (sub {}) x int @commands;
  }

  push @$mqueue, @commands;
  $self->connect unless $self->{_connection};
  $self->_send_next_message;

  return $self;
}

sub _send_next_message {
  my ($self) = @_;

  if ((my $id = $self->{_connection}) && !$self->{_connecting}) {
    while (my $args = shift @{$self->{_message_queue}}) {
      my $cmd_arg = [];
      my $cmd = {type => '*', data => $cmd_arg};
      foreach my $token (@$args) {
        $token = Encode::encode($self->encoding, $token)
          if $self->encoding;
        push @$cmd_arg, {type => '$', data => $token};
      }
      my $message = $self->protocol->encode($cmd);

      $self->ioloop->stream($id)->write($message);
    }
  }
}


sub _reencode_message {
  my ($self, $message) = @_;
  my ($type, $data) = @{$message}{'type', 'data'};

  # Decode data
  if ($type ne '*' && $self->encoding && $data) {
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
  my $cb = shift @{$self->{_cb_queue}};

  eval {
    $self->$cb($data) if $cb;
    1;
  } or do {
    my $err=$@;
    warn "Failed with $err";
    $self->has_subscribers('error') ? $self->emit_safe(error => $err) : warn $err;
  };
}


sub _inform_queue {
  my ($self) = @_;

  for my $cb (@{$self->{_cb_queue}}) {
    eval {
      $self->$cb if $cb;
      1;
    } or do {
      my $err=$@;
      $self->has_subscribers('error') ? $self->emit_safe(error => $err) : warn $err;
    };
  }

  $self->{_queue} = [];
}

1;
__END__

=head1 NAME

Mojo::Redis - asynchronous Redis client for L<Mojolicious>.

=head1 SYNOPSIS

    use Mojo::Redis;

    my $redis = Mojo::Redis->new(server => '127.0.0.1:6379');

    # Execute some commands
    $redis->ping(
        sub {
            my ($redis, $res) = @_;

            if (defined $res) {
                print "Got result: ", $res->[0], "\n";
            }
        }
    );

    # Work with keys
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

    get '/' => sub {
        my $self = shift;

        my $redis = mojo::redis->new(ioloop => mojo::ioloop->new);

        my $value;

        $redis->set(foo => 'bar')->get(
            foo => sub {
                my ($redis, $result) = @_;

                $redis->quit->ioloop->stop;
                $value = $result->[0];
            }
        )->ioloop->start;

        $self->render(text => qq(Foo value is "$value"));
    };

    app->start;

=head1 DESCRIPTION

L<Mojo::Redis> is an asynchronous client to Redis for Mojo.

=head1 EVENTS

=head2 error

    $redis->on(error => sub{
        my($redis, $error) = @_;
        warn "[REDIS ERROR] $error\n";
    });

Executes if error occured. Called before commands callbacks.

=head1 ATTRIBUTES

L<Mojo::Redis> implements the following attributes.

=head2 C<server>

    my $server = $redis->server;
    $redis     = $redis->server('127.0.0.1:6379');

C<Redis> server connection string, defaults to '127.0.0.1:6379'.

=head2 C<ioloop>

    my $ioloop = $redis->ioloop;
    $redis     = $redis->ioloop(Mojo::IOLoop->new);

Loop object to use for io operations, by default a L<Mojo::IOLoop> singleton
object will be used.

=head2 C<timeout>

    my $timeout = $redis->timeout;
    $redis      = $redis->timeout(100);

Maximum amount of time in seconds a connection can be inactive before being
dropped, defaults to C<300>.

=head2 C<encoding>

    my $encoding = $redis->encoding;
    $redis       = $redis->encoding('UTF-8');

Encoding used for stored data, defaults to C<UTF-8>.

=head2 C<protocol_redis>

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

=head2 C<connect>

    $redis = $redis->connect;

Connect to C<Redis> server.

=head2 C<execute>

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
            my($redis, $get, $lrange, $hmset) = @_;
            # ...
        },
    );

Execute specified command on C<Redis> server. If error occured during
request $result will be set to undef, error string can be obtained with 
the L</error> event.

=head2 C<subscribe>

   $id = $redis->subscribe('foo','bar' => sub {
    my ($redis,$res)=@_;
    # Called for subscribe messages and all publish calls.
   });

Opens up a new connection that subscribes to the given pubsub channels
returns the id of the connection in the L<Mojo::IOLoop>.

=head1 REDIS METHODS

=head2 append

=head2 auth

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

=head2 publish

=head2 punsubscribe

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

=head2 sunion

=head2 sunionstore

=head2 sync

=head2 ttl

=head2 type

=head2 unsubscribe

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

=head2 IRC

    #mojo on irc.perl.org

=head1 DEVELOPMENT

=head2 Repository

    https://github.com/und3f/mojox-redis

=head1 AUTHOR

Sergey Zasenko, C<undef@cpan.org>.

Forked from MojoX::Redis and updated to new IOLoop API by
Marcus Ramberg C<mramberg@cpan.org>.

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2010-2011, Sergey Zasenko
          (C) 2012, Marcus Ramberg

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=cut
