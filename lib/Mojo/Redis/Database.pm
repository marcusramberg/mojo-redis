package Mojo::Redis::Database;
use Mojo::Base 'Mojo::EventEmitter';

has connection => sub { Carp::confess('connection is not set') };
has redis      => sub { Carp::confess('redis is not set') };

sub DESTROY {
  my $self = shift;
  return unless (my $redis = $self->redis) && (my $conn = $self->connection);
  $redis->_enqueue($conn);
}

1;
