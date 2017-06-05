package Mojo::Redis::Connection;
use Mojo::Base 'Mojo::EventEmitter';

use Mojo::IOLoop;
use Mojo::Util;

use constant DEBUG => $ENV{MOJO_REDIS_DEBUG};

has encoding => 'UTF-8';
has protocol => sub { Carp::confess('protocol is not set') };
has url      => sub { Carp::confess('url is not set') };
has _loop    => sub { Mojo::IOLoop->singleton };

sub connect {
  my ($self, $cb) = @_;
  $self->once(connect => $cb) if $cb;
  return $self if $self->{id};    # Connecting
  Scalar::Util::weaken($self);

  $self->protocol->on_message(
    sub {
      my ($protocol, $message) = @_;
      my $cb = shift @{$self->{waiting} || []};
      $self->$cb('', $message->{data}) if $cb;
      $self->_write;
    }
  );

  my $url = $self->url;
  my $db  = $url->path->[0];

  $self->{id} = $self->_loop->client(
    {address => $url->host, port => $url->port || 6379},
    sub {
      my ($loop, $err, $stream) = @_;
      my $close_cb = $self->_on_close_cb;
      return $self->$close_cb($err) if $err;

      warn "[$self->{url}] CONNECTED\n" if DEBUG;
      $stream->timeout(0);
      $stream->on(close => $close_cb);
      $stream->on(error => $close_cb);
      $stream->on(read  => $self->_on_read_cb);

      unshift @{$self->{write}}, ["SELECT $db"] if $db;
      unshift @{$self->{write}}, ["AUTH @{[$url->password]}"] if length $url->password;

      $self->{stream} = $stream;
      $self->emit('connect');
      $self->_write;
    },
  );

  warn "[$self->{url}] CONNECTING\n" if DEBUG;
  return $self;
}

sub connected { shift->{stream} ? 1 : 0 }

sub disconnect {
  my $self = shift;
  $self->{stream}->close if $self->{stream};
  return $self;
}

sub write {
  my $cb       = ref $_[-1] eq 'CODE' ? pop : undef;
  my $self     = shift;
  my $encoding = $self->encoding;

  push @{$self->{write}},
    [$self->protocol->encode({type => '*', data => [map { +{type => '$', data => $_} } @_]}), $cb];

  $self->{stream} ? $self->_loop->next_tick(sub { $self->_write }) : $self->connect;
  return $self;
}

sub _on_close_cb {
  my $self = shift;

  Scalar::Util::weaken($self);
  return sub {
    return unless $self;
    my ($stream, $err) = @_;
    delete $self->{$_} for qw(id stream);
    $self->emit(error => $err) if $err;
    warn qq([$self->{url}] @{[$err ? "ERROR $err" : "CLOSED"]}\n) if DEBUG;
  };
}

sub _on_read_cb {
  my $self = shift;

  Scalar::Util::weaken($self);
  return sub {
    my ($stream, $chunk) = @_;
    do { local $_ = $chunk; s!\r\n!\\r\\n!g; warn "[$self->{url}] >>> ($_)\n" } if DEBUG;
    $self->protocol->parse($chunk);
  };
}

sub _write {
  my $self  = shift;
  my $loop  = $self->_loop;
  my $queue = $self->{write} || [];

  return unless @$queue;

  # Make sure connection has not been corrupted while event loop was stopped
  if (!$self->_loop->is_running and $self->{stream}->is_readable) {
    delete($self->{stream})->close;
    delete $self->{id};
    $self->connect;
    return $self;
  }

  my $op = shift @$queue;
  do { local $_ = $op->[0]; s!\r\n!\\r\\n!g; warn "[$self->{url}] <<< ($_)\n" } if DEBUG;
  push @{$self->{waiting}}, $op->[1] || sub { shift->emit(error => $_[1]) if $_[1] };
  $self->{stream}->write($op->[0]);
}

1;
