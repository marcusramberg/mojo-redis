package Mojo::Redis;
use Mojo::Base -base;

use Mojo::URL;

has max_connections => 5;
has url => sub { Mojo::URL->new('redis://localhost:6379') };

sub db { Mojo::Redis::Database->new(connection => $_[0]->_dequeue, redis => $_[0]); }
sub new { @_ > 1 ? shift->SUPER::new->from_string(@_) : shift->SUPER::new }
sub pubsub { Mojo::Redis::PubSub->new(connection => $_[0]->_dequeue, redis => $_[0]) }
sub from_string { ref $_[1] ? $_[1] : Mojo::URL->new($_[1]) }

sub _dequeue {
  my $self = shift;
  delete @$self{qw(pid queue)} unless ($self->{pid} //= $$) eq $$;    # Fork-safety
  while (my $conn = shift @{$self->{queue} || []}) { return $conn if $conn->ping }
  return Mojo::Redis::Connection->new(url => $self->url);
}

sub _enqueue {
  my ($self, $conn) = @_;
  my $queue = $self->{queue} ||= [];
  push @$queue, $conn if $conn->connected;
  shift @$queue while @$queue > $self->max_connections;
}

1;
