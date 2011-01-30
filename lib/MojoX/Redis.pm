package MojoX::Redis;

use strict;
use warnings;

our $VERSION = 0.7;
use base 'Mojo::Base';

use Mojo::IOLoop;
use List::Util   ();
use Mojo::Util   ();
use Scalar::Util ();
use Carp 'croak';

__PACKAGE__->attr(server   => '127.0.0.1:6379');
__PACKAGE__->attr(ioloop   => sub { Mojo::IOLoop->singleton });
__PACKAGE__->attr(error    => undef);
__PACKAGE__->attr(timeout  => 300);
__PACKAGE__->attr(encoding => 'UTF-8');
__PACKAGE__->attr(
    on_error => sub {
        sub {
            my $redis = shift;
            warn "Redis error: ", $redis->error, "\n";
          }
    }
);

our @COMMANDS = qw/
  append auth bgrewriteaof bgsave blpop brpop brpoplpush config_get config_set
  config_resetstat dbsize debug_object debug_segfault decr decrby del discard
  echo exec exists expire expireat flushall flushdb get getbit getrange getset
  hdel hexists hget hgetall hincrby hkeys hlen hmget hmset hset hsetnx hvals
  incr incrby info keys lastsave lindex linsert llen lpop lpush lpushx lrange
  lrem lset ltrim mget monitor move mset msetnx multi persist ping psubscribe
  publish punsubscribe quit randomkey rename renamenx rpop rpoplpush rpush
  rpushx sadd save scard sdiff sdiffstore select set setbit setex setnx
  setrange shutdown sinter sinterstore sismember slaveof smembers smove sort
  spop srandmember srem strlen subscribe sunion sunionstore sync ttl type
  unsubscribe unwatch watch zadd zcard zcount zincrby zinterstore zrange
  zrangebyscore zrank zrem zremrangebyrank zremrangebyscore zrevrange
  zrevrangebyscore zrevrank zscore zunionstore
/;

sub AUTOLOAD {
    my ($package, $cmd) = our $AUTOLOAD =~ /^([\w\:]+)\:\:(\w+)$/;

    Carp::croak(qq|Can't locate object method "$cmd" via "$package"|)
        unless List::Util::first {$_ eq $cmd} @COMMANDS;

    my $self = shift;

    my $args = [@_];
    my $cb   = $args->[-1];
    if (ref $cb ne 'CODE') {
        $cb = undef;
    } else {
        pop @$args;
    }

    $self->execute($cmd, $args, $cb);
}

sub DESTROY {
    my $self = shift;

    # Loop
    return unless my $loop = $self->ioloop;

    # Cleanup connection
    $loop->drop($self->{_connection})
      if $self->{_connection};
}

sub connect {
    my $self = shift;

    # drop old connection
    if ($self->connected) {
        $self->ioloop->drop($self->{_connection});
    }

    $self->server =~ m{^([^:]+)(:(\d+))?};
    my $address = $1;
    my $port = $3 || 6379;

    Scalar::Util::weaken $self;

    # connect
    $self->{_connecting} = 1;
    $self->{_connection} = $self->ioloop->connect(
        {   address    => $address,
            port       => $port,
            on_connect => sub { $self->_on_connect(@_) },
            on_read    => sub { $self->_read_wait_command(@_) },
            on_error   => sub { $self->_on_error(@_) },
            on_hup     => sub { $self->_on_hup(@_) },
        }
    );

    return $self;
}

sub connected {
    my $self = shift;

    return $self->{_connection};
}

sub execute {
    my ($self, $command, $args, $cb) = @_;

    if (!$cb && ref $args eq 'CODE') {
        $cb   = $args;
        $args = [];
    }
    elsif (!ref $args) {
        $args = [$args];
    }

    unshift @$args, uc $command;

    my $message = '*' . scalar(@$args) . "\r\n";
    foreach my $token (@$args) {
        Mojo::Util::encode($self->encoding, $token) if $self->encoding;
        $message .= '$' . length($token) . "\r\n" . "$token\r\n";
    }
    $message .= "\r\n";

    my $mqueue = $self->{_message_queue} ||= [];
    my $cqueue = $self->{_cb_queue}      ||= [];


    push @$mqueue, $message;
    push @$cqueue, $cb;

    $self->connect unless $self->{_connection};
    $self->_send_next_message;

    return $self;
}

sub start {
    my ($self) = @_;

    $self->ioloop->start;
    return $self;
}

sub stop {
    my ($self) = @_;

    $self->ioloop->stop;
    return $self;
}

sub _send_next_message {
    my ($self) = @_;

    if ((my $c = $self->{_connection}) && !$self->{_connecting}) {
        while (my $message = shift @{$self->{_message_queue}}) {
            $self->ioloop->write($c, $message);
        }
    }
}

sub _on_connect {
    my ($self, $ioloop, $id) = @_;
    delete $self->{_connecting};

    $ioloop->connection_timeout($id => $self->timeout);

    $self->_send_next_message;
}

sub _return_command_data {
    my ($self, $data) = @_;

    my $cb = shift @{$self->{_cb_queue}};
    if ($cb) {

        # Decode data
        if ($self->encoding && $data) {
            Mojo::Util::decode($self->encoding, $_) for @$data;
        }

        $cb->($self, $data);
    }

    # Reset error after callback dispatching
    $self->error(undef);
}

sub _on_error {
    my ($self, $ioloop, $id, $error) = @_;

    $self->error($error);
    $self->_inform_queue;

    $self->on_error->($self);

    $ioloop->drop($id);
}

sub _on_hup {
    my ($self, $ioloop, $id) = @_;

    $self->{error} ||= 'disconnected';
    $self->_inform_queue;

    delete $self->{_message_queue};

    delete $self->{_connecting};
    delete $self->{_connection};
}

sub _inform_queue {
    my ($self) = @_;

    for my $cb (@{$self->{_cb_queue}}) {
        $cb->($self) if $cb;
    }
    $self->{_queue} = [];
}

sub _read_wait_command {
    my ($self, $ioloop, $id, $chunk) = @_;

    Scalar::Util::weaken $self;
    my $cmd = substr $chunk, 0, 1, '';
    if (!defined $chunk || $chunk eq '') {

        # Wait next command
        $ioloop->on_read($id => sub { $self->_read_wait_command(@_) });
    }
    elsif (List::Util::first { $cmd eq $_ } ('+', '-', ':')) {

        # Just a simple one line command
        $self->{_read_cmd_string} = '';
        if ($cmd ne '-') {
            $self->{_read_cb} = sub {
                $self->_return_command_data(shift);
                $self->_read_wait_command($self->ioloop, $id, shift);
            };
        }
        else {
            $self->{_read_cb} = sub {
                $self->error(shift->[0]);
                $self->on_error->($self);
                $self->_return_command_data(undef);
                $self->_read_wait_command($self->ioloop, $id, shift);
            };
        }

        $ioloop->on_read($id => sub { $self->_read_string_command(@_); });
        $self->_read_string_command($self->ioloop, $id, $chunk);

    }
    elsif ($cmd eq '$') {

        # Bulk command, not a big deal
        $self->{_read_cb} = sub {
            $self->_return_command_data(shift);
            $self->_read_wait_command($self->ioloop, $id, shift);
        };

        # Yes, it should have leading $
        $self->_read_bulk_command($ioloop, $id, "\$$chunk");
    }
    elsif ($cmd eq '*') {
        $self->{_read_cb} = sub {
            $self->_return_command_data(shift);
            $self->_read_wait_command($self->ioloop, $id, shift);
        };
        $self->_read_multi_bulk_command($ioloop, $id, $chunk);
    }
    else {
        die qq{Strange input "$cmd$chunk"};
    }
}

sub _read_string_command {
    my ($self, $ioloop, $id, $chunk) = @_;

    my $str = $self->{_read_cmd_string} .= $chunk;
    my $i = index $str, "\r\n";

    if ($i >= 0) {

        # Got full command
        my $result = substr $str, 0, $i, '';
        substr $str, 0, 2, '';    # Delete \r\n

        #print "## $result\n## $str\n";
        my $cb = $self->{_read_cb};
        delete $self->{_read_cb};
        delete $self->{_read_cmd_string};
        $cb->([$result], $str);
    }
}

sub _read_multi_bulk_command {
    my ($self, $ioloop, $id, $chunk) = @_;

    delete $self->{_read_cmd_num};

    my $mbulk_cb = $self->{_read_cb};

    my $results = [];
    my $mbulk_process;
    $mbulk_process = sub {
        push @$results, shift->[0];

        if (scalar @$results == $self->{_read_cmd_num}) {
            $mbulk_process = undef;
            $mbulk_cb->($results, shift);
        }
        else {

            # Read another string
            #print "### Got another result: ", $results->[-1], "\n";;
            $self->{_read_cb} = $mbulk_process;
            $self->_read_bulk_command($ioloop, $id, shift);
        }
    };

    # Read number of commands
    $self->{_read_cb} = sub {
        $self->{_read_cmd_num} = shift->[0];
        my $chunk = shift;

        if ($self->{_read_cmd_num} < 1) {
            $mbulk_process = undef;
            $mbulk_cb->($results, $chunk);
            return;
        }

        #print "Got #commands: ", $self->{_read_cmd_num}, "\n";
        $self->{_read_cb} = $mbulk_process;
        $ioloop->on_read($id => sub { $self->_read_bulk_command(@_) });
        $self->_read_bulk_command($ioloop, $id, $chunk);
    };

    $ioloop->on_read($id => sub { $self->_read_string_command(@_); });
    $self->_read_string_command($ioloop, $id, $chunk);
}

sub _read_bulk_command {
    my ($self, $ioloop, $id, $chunk) = @_;

    delete $self->{_read_cmd_legth};

    my $bulk_cb = $self->{_read_cb};

    # Read size of string
    $self->{_read_cb} = sub {
        my $size  = shift->[0];
        my $chunk = shift;

        # Delete leading $
        substr $size, 0, 1, "";
        $self->{_read_cmd_legth} = $size;

        #print "Got size: ", $self->{_read_cmd_legth}, "\n";
        $self->{_read_cb} = $bulk_cb;

        if ($size == '-1') {
            $self->{_read_cb}->([], $chunk);
        }
        else {
            $ioloop->on_read(
                $id => sub { $self->_read_bulk_command_string(@_) });
            $self->_read_bulk_command_string($ioloop, $id, $chunk);
        }
    };

    $ioloop->on_read($id => sub { $self->_read_string_command(@_); });
    $self->_read_string_command($ioloop, $id, $chunk);
}

sub _read_bulk_command_string {
    my ($self, $ioloop, $id, $chunk) = @_;

    my $str = $self->{_read_cmd_string} .= $chunk;

    #print "String $str\n";
    if (length $str >= $self->{_read_cmd_legth}) {
        my $result = substr $str, 0, $self->{_read_cmd_legth}, "";
        substr $str, 0, 2, "";    # Delete \r\n

        #print "## str result $result\n";
        my $cb = $self->{_read_cb};
        delete $self->{_read_cb};
        delete $self->{_read_cmd_string};
        $cb->([$result], $str);
    }
}

1;
__END__

=head1 NAME

L<MojoX::Redis> - asynchronous Redis client for L<Mojolicious>.

=head1 SYNOPSIS

    use MojoX::Redis;

    my $redis = MojoX::Redis->new(server => '127.0.0.1:6379');

    # Execute some commands
    $redis->ping(
        sub {
            my ($redis, $res) = @_;

            if ($res) {
                print "Got result: ", $res->[0], "\n";
            }
            else {
                print "Error: ", $redis->error, "\n";
            }
      })

      # Work with keys
      ->set(key => 'value')

      ->get(key => sub {
          my ($redis, $res) = @_;

          print "Value of ' key ' is $res->[0]\n";
      })


      # Cleanup connection
      ->quit(sub { shift->stop })->start;

=head1 DESCRIPTION

L<MojoX::Redis> is an asynchronous client to Redis for Mojo.

=head1 ATTRIBUTES

L<MojoX::Redis> implements the following attributes.

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

=head1 METHODS

L<MojoX::Redis> supports Redis' methods.

    $redis->set(key => 'value);
    $redis->get(key => sub { ... });

For more details take a look at C<execute> method.

Also L<MojoX::Redis> implements the following ones.

=head2 C<connect>

    $redis = $redis->connect;

Connect to C<Redis> server.

=head2 C<execute>

    $redis = $redis->execute("ping" => sub{
        my ($redis, $result) = @_;

        # Process result
    });
    $redis->execute(lrange => ["test", 0, -1] => sub {...});
    $redis->execute(set => [test => "test_ok"]);

Execute specified command on C<Redis> server. If error occured during
request $result will be set to undef, error string can be obtained with 
$redis->error.

=head2 C<error>

    $redis->execute("ping" => sub {
        my ($redis, $result) = @_;
        die $redis->error unless defined $result;
    }

Returns error occured during command execution.
Note that this method returns error code just from current command and
can be used just in callback.

=head2 C<on_error>

    $redis->on_error(sub{
        my $redis = shift;
        warn 'Redis error ', $redis->error, "\n";
    });

Executes if error occured. Called before commands callbacks.

=head2 C<start>

    $redis->start;

Starts IOLoop. Shortcut for $redis->ioloop->start;

=head1 SEE ALSO

L<Mojolicious>, L<Mojo::IOLoop>

=head1 SUPPORT

=head2 IRC

    #ru.pm on irc.perl.org
    
=head1 DEVELOPMENT

=head2 Repository

    http://github.com/und3f/mojoliciousx-lexicon

=head1 AUTHOR

Sergey Zasenko, C<undef@cpan.org>.

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2010, Sergey Zasenko

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=cut
