package Mojo::Redis;

our $VERSION = 0.9;
use Mojo::Base 'Mojo::EventEmitter';

use Mojo::IOLoop;
use Scalar::Util ();
use Encode       ();
require Carp;

has server   => '127.0.0.1:6379';
has ioloop   => sub { Mojo::IOLoop->singleton };
has error    => undef;
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
          $self->{error} = $error;
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
          $self->{error} ||= 'disconnected';
          $self->_inform_queue;

          delete $self->{_message_queue};
          delete $self->{_connecting};
          delete $self->{_connection};
        }
      );
      $stream->on(
        error => sub {
          my ($str, $error) = @_;
          $self->error($error);
          $self->_inform_queue;

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
          $self->error($error);

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
    $self->error($data);
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
    $self->has_subscribers('error') ? $self->emit_safe(error => $@) : warn $@;
  };

  # Reset error after callback dispatching
  $self->error(undef);
}


sub _inform_queue {
  my ($self) = @_;

  for my $cb (@{$self->{_cb_queue}}) {
    eval {
      $self->$cb if $cb;
      1;
    } or do {
      $self->has_subscribers('error') ? $self->emit_safe(error => $@) : warn $@;
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
            else {
                print "Error: ", $redis->error, "\n";
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

                return app->log->error($redis->error) unless $result;

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
        my $redis = shift;
        warn 'Redis error ', $redis->error, "\n";
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
$redis->error.

=head2 C<subscribe>

   $id = $redis->subscribe('foo','bar' => sub {
    my ($redis,$res)=@_;
    # Called for subscribe messages and all publish calls.
   });

Opens up a new connection that subscribes to the given pubsub channels
returns the id of the connection in the L<Mojo::IOLoop>.

=head2 C<error>

    $redis->execute("ping" => sub {
        my ($redis, $result) = @_;
        die $redis->error unless defined $result;
    });

Returns error occured during command execution.
Note that this method returns error code just from current command and
can be used just in callback.

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
