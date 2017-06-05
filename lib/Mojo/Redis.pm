package Mojo::Redis;
use Mojo::Base 'Mojo::EventEmitter';

use Mojo::URL;
use Mojo::Redis::Connection;
use Mojo::Redis::Database;
use Mojo::Redis::PubSub;

has protocol_class => do {
  my $class = $ENV{MOJO_REDIS_PROTOCOL};
  $class ||= eval q(require Protocol::Redis::XS; 'Protocol::Redis::XS');
  $class ||= 'Protocol::Redis';
  eval "require $class; 1" or die $@;
  $class;
};

has max_connections => 5;

has pubsub => sub {
  my $pubsub = Mojo::Redis::PubSub->new(connection => $_[0]->_dequeue, redis => $_[0]);
  Scalar::Util::weaken($pubsub->{redis});
  return $pubsub;
};

has url => sub { Mojo::URL->new('redis://localhost:6379') };

sub db { Mojo::Redis::Database->new(connection => $_[0]->_dequeue, redis => $_[0]); }
sub new { @_ == 2 ? $_[0]->SUPER::new->url(Mojo::URL->new($_[1])) : $_[0]->SUPER::new }

sub _dequeue {
  my $self = shift;
  delete @$self{qw(pid queue)} unless ($self->{pid} //= $$) eq $$;    # Fork-safety

  # Exsting connection
  while (my $conn = shift @{$self->{queue} || []}) { return $conn if $conn->connected }

  # New connection
  my $conn = Mojo::Redis::Connection->new(protocol => $self->protocol_class->new(api => 1), url => $self->url);
  Scalar::Util::weaken($self);
  $conn->on(connect => sub { $self->emit(connection => $_[0]) });
  return $conn;
}

sub _enqueue {
  my ($self, $conn) = @_;
  my $queue = $self->{queue} ||= [];
  push @$queue, $conn if $conn->connected;
  shift @$queue while @$queue > $self->max_connections;
}

1;
