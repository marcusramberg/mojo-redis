package MojoX::Redis;

use strict;
use warnings;

our $VERSION = 0.3;
use base 'Mojo::Base';

use Mojo::IOLoop;
use List::Util ();
use Mojo::Util ();

__PACKAGE__->attr(server   => '127.0.0.1:6379');
__PACKAGE__->attr(ioloop   => sub { Mojo::IOLoop->singleton });
__PACKAGE__->attr(error    => undef);
__PACKAGE__->attr(timeout  => 300);
__PACKAGE__->attr(encoding => 'UTF-8');

sub connect {
    my $self = shift;

    # drop old connection
    if ($self->{_connection}) {
        $self->ioloop->drop($self->{_connection});
    }

    $self->server =~ m{^([^:]+)(:(\d+))?};
    my $address = $1;
    my $port = $3 || 6379;

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
        $cb->($data);
    }

    $self->error(undef);
}

sub _on_error {
    my ($self, $ioloop, $id, $error) = @_;

    $self->error($error);
    $self->_inform_queue;
}

sub _on_hup {
    my ($self, $ioloop, $id) = @_;

    $self->{error} ||= 'disconnected';
    $self->_inform_queue;
}

sub _inform_queue {
    my ($self) = @_;

    for my $cb (@{$self->{_cb_queue}}) {
        $cb->() if $cb;
    }
    $self->{_queue} = [];
}

sub _read_wait_command {
    my ($self, $ioloop, $id, $chunk) = @_;

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
                $self->_read_wait_command($ioloop, $id, shift);
            };
        }
        else {
            $self->{_read_cb} = sub {
                $self->error(shift->[0]);
                $self->_return_command_data(undef);
                $self->_read_wait_command($ioloop, $id, shift);
            };
        }

        $ioloop->on_read($id => sub { $self->_read_string_command(@_); });
        $self->_read_string_command($ioloop, $id, $chunk);

    }
    elsif ($cmd eq '$') {

        # Bulk command, not a big deal
        $self->{_read_cb} = sub {
            $self->_return_command_data(shift);
            $self->_read_wait_command($ioloop, $id, shift);
        };

        # Yes, it should have leading $
        $self->_read_bulk_command($ioloop, $id, "\$$chunk");
    }
    elsif ($cmd eq '*') {
        $self->{_read_cb} = sub {
            $self->_return_command_data(shift);
            $self->_read_wait_command($ioloop, $id, shift);
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

        #print "Got #commands: ", $self->{_read_cmd_num}, "\n";
        $self->{_read_cb} = $mbulk_process;
        $ioloop->on_read($id => sub { $self->_read_bulk_command(@_) });
        $self->_read_bulk_command($ioloop, $id, shift);
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

MojoX::Redis - asynchronous Redis client based on Mojo

=head1 SYNOPSIS

    use MojoX::Redis;

    # Create redis client 
    my $r = MojoX::Redis->new( server => '127.0.0.1:6379' );

    # Execute some commands
    $r->execute( ping, sub {
        my $res = shift;

        if ( $res ) {
            print "Got result: ", $res->[0], "\n";
        } else {
            print "Error: ", $r->error, "\n";
        }
        $r->ioloop->stop;
    }

    # ioloop should be running
    $r->ioloop->start;

=head1 DESCRIPTION

MojoX::Redis works

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::IOLoop>

=head1 AUTHOR

Sergey Zasenko, C<d3fin3@gmail.com>.

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2010, Sergey Zasenko

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=cut
