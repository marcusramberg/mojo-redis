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
  my $self     = shift;
  my $url      = $self->url;
  my $db       = $url->path->[0];
  my @userinfo = split /:/, +($url->userinfo // '');
  my $id;

  return $self if $self->{id};

  Scalar::Util::weaken($self);

  $self->protocol->on_message(
    sub {
      my ($protocol, $message) = @_;
      my $cb = shift @{$self->{waiting} || []};
      $self->$cb('', $message->{data}) if $cb;
      $self->_write;
    }
  );

  warn "[$self->{url}] CONNECTING\n" if DEBUG;
  $self->{id} = $self->_loop->client(
    {address => $url->host, port => $url->port || 6379},
    sub {
      my ($loop, $err, $stream) = @_;
      return $self->_close($err) if $err;

      warn "[$self->{url}] CONNECTED\n" if DEBUG;
      $self->emit('connect');
      $stream->timeout(0);
      $stream->on(close => sub { $self and $self->_close });
      $stream->on(error => sub { $self and $self->_close($_[1]) });
      $stream->on(read  => sub { $self->_read($_[1]) });

      # NOTE: unshift() will cause AUTH to be sent before SELECT
      unshift @{$self->{write}}, [SELECT => $db]          if $db;
      unshift @{$self->{write}}, [AUTH   => $userinfo[1]] if length $userinfo[1];

      $self->{stream} = $stream;
      $self->_write;
    },
  );

  return $self;
}

sub connected { shift->{stream} ? 1 : 0 }

sub disconnect {
  my $self = shift;
  $self->{stream}->close if $self->{stream};
  return $self;
}

sub write {
  my $cb       = ref $_[-1] eq 'CODE' ? pop : sub { shift->emit(error => $_[1]) if $_[1] };
  my $self     = shift;
  my $encoding = $self->encoding;

  push @{$self->{write}},
    [$self->protocol->encode({type => '*', data => [map { +{type => '$', data => $_} } @_]}), $cb];

  $self->{stream} ? $self->_loop->next_tick(sub { $self->_write }) : $self->connect;
  return $self;
}

sub _close {
  my ($self, $err) = @_;
  delete $self->{$_} for qw(id stream);
  $self->emit(error => $err) if $err;
  warn "[$self->{url}] ERROR $err\n" if DEBUG and $err;
  warn "[$self->{url}] CLOSED\n"     if DEBUG and !$err;
  return $self;
}

sub _read {
  my ($self, $chunk) = @_;
  my $protocol = $self->protocol;

  do { local $_ = $chunk; s!\r\n!\\r\\n!g; warn "[$self->{url}] >>> ($_)\n" } if DEBUG;
  $protocol->parse($chunk);
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
  push @{$self->{waiting}}, $op->[1];
  $self->{stream}->write($op->[0]);
}

1;
