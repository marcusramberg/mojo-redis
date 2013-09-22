package Mojo::Redis::Subscription;

=head1 NAME

Mojo::Redis::Subscription - Result of Mojo::Redis->subscribe()

=head1 SYNOPSIS

You can create a L<Mojo::Redis::Subscription> object in two ways:

Either from L<Mojo::Redis>:

  use Mojo::Redis;
  $r = Mojo::Redis->new;
  $s = $r->subscribe('foo'); # does also ->connect()
  print @{ $s->channels } # print "foo";

...or from L<Mojo::Redis::Subscription>:

  use Mojo::Redis::Subscription;
  my $s = Mojo::Redis::Subscription->new;
  $s->channels(['foo']);
  $s->connect;

Either way you need to subscribe to an event:

  $s->on(message => sub {
      my($s, $message, $channel) = @_;
  });

  Mojo::IOLoop->start;

=cut

use Mojo::Base 'Mojo::Redis'; # This may change in the future!

=head1 EVENTS

=head2 message

  $self->on(message => sub { my($self, $message, $channel) = @_; ... });

This event receive the messages sent over the channel.

=head2 data

  $self->on(data => sub { my($self, $data) = @_; ... });

This event receive all data sent over the channel. Example:

  0: ['subscribe', 'first_channel_name', 1];
  1: ['message', 'first_channel_name','yay!']

=head1 ATTRIBUTES

=head2 channels

Holds an array ref of channel names which this object subscribe to.

=cut

has channels => sub { [] };

=head2 type

Describes the sort of subscription this object is using: subscribe or psubscribe.

=cut

has type => 'subscribe';

=head1 METHODS

=head2 connect

Used to connect to the redis server and start subscribing to the L</channels>.
This is called automatically from L<Mojo::Redis/subscribe>.

=cut

sub connect {
  my $self = shift;
  my $channels = $self->channels;
  my $command = $self->type;

  $self->SUPER::connect(@_);

  push @{ $self->{cb_queue} }, (sub { shift->emit(data => @_) }) x (@$channels - 1);

  $self->execute(
    [ $command => @$channels ],
    sub {
      my $self = shift;
      Scalar::Util::weaken($self);
      $self->emit(data => @_);
      $self->protocol->on_message(sub {
        my ($parser, $message) = @_;
        my $data = $self->_reencode_message($message) or return;
        $self->emit(data => $data);
        $self->emit(message => @$data[2, 1]) if $data->[0] eq 'message';
        $self->emit(message => @$data[3, 2, 1]) if $data->[0] eq 'pmessage';
      });
    }
  );
}

=head2 disconnect

Will remove the connection to the redis server. This also happen when the
object goes out of scope.

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut

1;
