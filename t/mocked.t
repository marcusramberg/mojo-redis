use t::Helper;
use Mojo::Redis;

plan tests => 6;

my(@chunk, @write, $server, $stream);
my $port = generate_port();
my $n = 0;

$server = Mojo::IOLoop->server(
            {
              port => $port,
            },
            sub {
              $stream = $_[1];
              $stream->on(read => sub {
                push @chunk, split /\r\n/, $_[1];
              });
            },
          );

my $redis = Mojo::Redis->new(server => "127.0.0.1:$port", timeout => 2);

Mojo::IOLoop->recurring(0.05 => sub {
  @write or return;
  $stream or return;
  $stream->write(sprintf "%s\r\n", shift @write); # write in chunks
});

$redis->on(error => sub {
  my($redis, $error) = @_;
  diag $error;
  $redis->ioloop->stop;
});

{
  queue(
    method => 'get',
    args => [ 'some_key' ],
    result => [ 'some data' ],
    chunk => [ '*2', '$3', 'GET', '$8', 'some_key' ],
  );

  @write = ('$9', 'some data');
  $redis->ioloop->start;
}

{
  queue(
    method => 'execute',
    args => [
      [ set => 'name' => 'Batman' ],
      [ set => 'age' => 25 ],
    ],
    result => [ 'OK', 'OK' ],
    chunk => [
      '*3', '$3', 'SET', '$4', 'name', '$6', 'Batman',
      '*3', '$3', 'SET', '$3', 'age', '$2', 25,
    ],
  );
  queue(
    method => 'get',
    args => [ 'name' ],
    result => [ 'Batman' ],
    chunk => [ '*2', '$3', 'GET', '$4', 'name' ],
  );

  @write = (
    '$2', 'OK',
    '$2', 'OK',
    '$6', 'Batman',
  );
  $redis->ioloop->start;
}

sub queue {
  my %args = @_;
  my $method = $args{method};
  my @args = @{ $args{args} };
  my $size = @{ $args{chunk} };

  for(@args) {
    $_ = join ',', @{ $_ } if ref $_ eq 'ARRAY';
  }

  $n++;
  $redis->$method(@{ $args{args} }, sub {
    my($redis, @result) = @_;

    is_deeply \@result, $args{result}, "$method @args result";
    is_deeply [splice @chunk, 0, $size, ()], $args{chunk}, "$method @args chunk";

    $redis->ioloop->stop if --$n == 0;
  });
}
