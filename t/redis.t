#!/usr/bin/env perl

# Becouse of two async applications working together this tests look ugly
# if you want to examine MojoX::Redis API take a look at t/redis_live.t

use strict;
use warnings;

use Test::More tests => 8;

use Mojo::IOLoop;

use_ok 'MojoX::Redis';

my $loop = Mojo::IOLoop->singleton;
my $port = $loop->generate_port;

my $redis =
  new_ok 'MojoX::Redis' => [server => "127.0.0.1:$port", timeout => 5];

my ($sbuffer1, $sbuffer2, $sbuffer3);
my ($r,        $r1,       $r2);
my $server;
$loop->listen(
    port    => $port,
    on_read => sub {
        my ($self, $id, $chunk) = @_;
        $sbuffer1 = $chunk;
        $self->write($id => "\$2\r\nok\r\n");
        $self->on_read($id => sub { });
    },
    on_accept => sub {
        my ($self, $id) = @_;
        $server = $id;
    }
);

$redis->execute(
    get => 'test',
    sub {
        my ($redis, $result) = @_;
        $r = $result;
        &test2;
    }
)->start;

# Multiple pipelined commands
sub test2 {
    $loop->on_read(
        $server => sub {
            my ($self, $id, $chunk) = @_;
            $sbuffer2 .= $chunk;

            # Wait both commands to come
            if ($sbuffer2 =~ m{test2}) {
                $self->on_read($id => sub { });

                # Half of first command
                $self->write($id => "\$3\r\nok");
                $self->timer(
                    0.1 => sub {
                        my ($self) = @_;

                        # Another half with first half of second
                        $self->write($id => "1\r\n\$3");
                        $self->timer(
                            0.1 => sub {
                                my ($self) = @_;

                                # Done
                                $self->write($id => "\r\nok2\r\n");
                                $self->timer(
                                    0.2 => sub {
                                        $self->stop;
                                    }
                                );
                            }
                        );
                    }
                );
            }
        }
    );
    $redis->execute(
        get => 'test1',
        sub {
            my ($redis, $result) = @_;
            $r1 = $result;
        }
      )->execute(
        get => 'test2',
        sub {
            my ($redis, $result) = @_;
            $r2 = $result;
            &check3;
        }
      );
}

sub check3 {
    $loop->on_read(
        $server => sub {
            my ($self, $id, $chunk) = @_;
            $sbuffer3 = $chunk;

            &tests_check;
        }
    );

    $redis->set(key => 'value', sub {});
}

sub tests_check {
    $redis->stop;

    is $sbuffer1, "*2\r\n\$3\r\nGET\r\n\$4\r\ntest\r\n\r\n", 'input command';
    is_deeply $r, ['ok'], 'result';

    is $sbuffer2,
      "*2\r\n\$3\r\nGET\r\n\$5\r\ntest1\r\n\r\n*2\r\n\$3\r\nGET\r\n\$5\r\ntest2\r\n\r\n",
      'input commands';
    is_deeply $r1, ['ok1'], 'first command';
    is_deeply $r2, ['ok2'], 'second command';

    is $sbuffer3, "*3\r\n\$3\r\nSET\r\n\$3\r\nkey\r\n\$5\r\nvalue\r\n\r\n",
      'fast command';
}
