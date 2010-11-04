package MojoX::Redis;

use strict;
use warnings;

our $VERSION = 0.1;
use base 'Mojo::Base';

use Mojo::IOLoop;

__PACKAGE__->attr( server => '127.0.0.1:6379' );
__PACKAGE__->attr( ioloop => sub { Mojo::IOLoop->singleton } );
__PACKAGE__->attr( error  => undef );

sub connect {
    my $self = shift;

    # drop old connection
    if ( $self->{_connection} ) {
        $self->ioloop->drop( $self->{_connection} );
    }

    $self->server=~m{^([^:]+)(:(\d+))?};
    my $address = $1;
    my $port    = $3 || 6379;
    # connect
    $self->{_connecting} = 1;
    $self->{_connection} = $self->ioloop->connect({
        address    => $address,
        port       => $port,
        on_connect => sub { $self->_on_connect(@_) },
        on_read    => sub { $self->_on_read(@_)    },
        on_error   => sub { $self->_on_error(@_)   },
        on_hup     => sub { $self->_on_hup(@_)     },
    });

    return $self;
}

sub execute {
    my ($self, $command, $args, $cb) = @_;

    if ( !$cb && ref $args eq 'CODE' ) {
        $cb   = $args;
        $args = [];
    } elsif ( ! ref $args ) {
        $args = [ $args ];
    }

    unshift @$args, uc $command;

    my $message = '*' . scalar(@$args) . "\r\n";
    foreach my $token (@$args) {
        $message .= '$' . length($token) . "\r\n"
                    . "$token\r\n";
                    
    }
    $message .= "\r\n";

    my $queue = $self->{_queue} ||= [];

    push @$queue, [ $message, $cb ];

    $self->connect unless ($self->{_connection} || $self->{_connecting});
    $self->_send_next_message;
    
    return $self;
}

sub _send_next_message {
    my ($self) = @_;

    $self->{_queue} ||= [];
    if ( (my $c = $self->{_connection}) && !$self->{_connecting}
        && !$self->{_command_cb}  && @{$self->{_queue}}
    )
    {
        my ($message, $cb) = @{shift @{$self->{_queue}}};
        $self->ioloop->write( $c, $message );
        $self->{_command_cb} = $cb || sub {};
        $self->error( undef );
    }
}

sub _on_connect {
    my ($self, $ioloop, $id) = @_;
    delete $self->{_connecting};

    # Kept connection alive (not forever, just first 10 years)
    # YES! It is the only way to disable timeout
    $ioloop->connection_timeout( $id => 315360000 );

    $self->_send_next_message;
}

sub _return_command_data {
    my ($self, @data) = @_;

    my $cb = $self->{_command_cb};
    $cb->( @data );

    delete $self->{_command_cb};
    $self->_send_next_message;
}

sub _on_read {
    my ($self, $ioloop, $id, $chunk) = @_;
    $self->{_buffer} .= $chunk;
    if ( $self->{_buffer}=~s{^([-+\:])([^\r\n]+)\r\n}{} ) {
        my ($status, $reply) = ($1, $2);
        if ($status eq '+' or $status eq ':') {
            $self->_return_command_data( [$reply] );
        } else {
            $self->error( $reply );
            $self->_return_command_data( undef );
        };
    } elsif ( my ($message, $reply) = $self->_read_bulk_reply( $self->{_buffer} ) ) {
        $self->{_buffer} = $message;
        $self->_return_command_data( [$reply] );
    } elsif ( $self->{_buffer} =~m{^\*(\d+)\r\n}p ) {
        my $count = $1;
        my $message = ${^POSTMATCH};
        my $reply;
        my @replies;
        for (1..$count) {
            if ( ($message, $reply) = $self->_read_bulk_reply( $message ) ) {
                push @replies, $reply;
            } else {
                # Not full command
                return
            }
        };
        $self->{_buffer} = $message;
        $self->_return_command_data( \@replies );
    }
}

sub _on_error {
    my ($self, $ioloop, $id, $error) = @_;

    $self->error( $error );

    $self->{_command_cb}->() if $self->{_command_cb};
    delete $self->{_command_cb};

    for my $message ( @{$self->{_queue}} ) {
        my $cb = $message->[1];
        $cb->() if $cb;
    }
    $self->{_queue} = [];
}

sub _on_hup {
    my ($self, $ioloop, $id) = @_;

    delete $self->{_connection};
    delete $self->{_connecting};
}

sub _read_bulk_reply {
    my ($self, $message) = @_;
     
    if ( $message=~m{^\$(\d+)\r\n}p ) {
        my $length = $1;
        return (${^POSTMATCH}, undef) if $length == -1;
        if ( ${^POSTMATCH}=~m{^(.{$length,$length})\r\n}p ) {
            return ${^POSTMATCH}, $1;
        }
    }
    return;
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
