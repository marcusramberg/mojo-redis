use Mojo::Base -strict;
use Test::More;
use Mojo::Redis;

plan skip_all => 'TEST_ONLINE=redis://localhost' unless $ENV{TEST_ONLINE};

my $redis = Mojo::Redis->new($ENV{TEST_ONLINE});

like $redis->protocol_class, qr{Protocol::Redis}, 'connection_class';
is $redis->max_connections, 5, 'max_connections';

my $db   = $redis->db;
my $conn = $db->connection;
isa_ok($db,   'Mojo::Redis::Database');
isa_ok($conn, 'Mojo::Redis::Connection');

# Create one connection
my $connected = 0;
my $err;
$conn->once(error => sub { $err = $_[1]; Mojo::IOLoop->stop });
is $conn->connect(sub { $connected++; Mojo::IOLoop->stop }), $conn, 'connect()';
Mojo::IOLoop->start;
is $connected, 1, 'connected' or diag $err;
is @{$redis->{queue} || []}, 0, 'zero connections in queue';

# Put connection back into queue
undef $db;
is @{$redis->{queue}}, 1, 'one connection in queue';

# Create more connections than max_connections
my @db;
push @db, $redis->db for 1 .. 6;    # one extra
$_->connection->connect->once(connect => sub { ++$connected == 6 and Mojo::IOLoop->stop }) for @db;
Mojo::IOLoop->start;

# Put max connections back into the queue
is $db[0]->connection, $conn, 'reusing connection';
@db = ();
is @{$redis->{queue}}, 5, 'five connections in queue';

# Take one connection out of the queue
$redis->db->connection->disconnect;
undef $db;
is @{$redis->{queue}}, 4, 'four connections in queue';

# Write and auto-connect
my @res;
delete $redis->{queue};
$db = $redis->db;
$db->connection->write(PING => sub { @res = @_[1, 2]; Mojo::IOLoop->stop });
Mojo::IOLoop->start;
is_deeply \@res, ['', 'PONG'], 'ping response';

done_testing;
