package Mojo::Redis::PubSub;
use Mojo::Base 'Mojo::EventEmitter';

has connection => sub { Carp::confess('connection is not set') };
has redis      => sub { Carp::confess('redis is not set') };
has _db        => sub {
  my $db = shift->redis->db;
  Scalar::Util::weaken($db->{redis});
  return $db;
};

sub listen {
  my ($self, $name, $cb) = @_;
  my $op = $name =~ /\*/ ? 'PSUBSCRIBE' : 'SUBSCRIBE';

  Scalar::Util::weaken($self);
  $self->connection->write($op => $name, sub { $self->_setup }) unless @{$self->{chans}{$name} ||= []};
  push @{$self->{chans}{$name}}, $cb;

  return $cb;
}

sub notify {
  my $self = shift;
  $self->_db->connection->write(PUBLISH => $_[0], $_[1]);
  return $self;
}

sub unlisten {
  my ($self, $name, $cb) = @_;
  my $chan = $self->{chans}{$name};
  my $op = $name =~ /\*/ ? 'PUNSUBSCRIBE' : 'UNSUBSCRIBE';

  @$chan = $cb ? grep { $cb ne $_ } @$chan : ();
  $self->connection->write($op => $name) and delete $self->{chans}{$name} unless @$chan;

  return $self;
}

sub _setup {
  my $self = shift;
  return if $self->{cb};

  Scalar::Util::weaken($self);
  $self->{cb} = $self->connection->on(
    message => sub {
      my ($conn, $message) = @_;
      my ($type, $name, $payload) = @{$message->{data}};
      for my $cb (@{$self->{chans}{$name->{data}}}) { $self->$cb($payload->{data}) }
    }
  );
}

1;
