use Mojo::Base -strict;
use Test::More;
use Mojo::Redis;

my $port = Mojo::IOLoop::Server->generate_port;
Mojo::IOLoop->server({port => $port}, sub { });

my $redis = Mojo::Redis->new("redis://whatever:s3cret\@localhost:$port/12");
is $redis->db->connection->url->port, $port, 'port';
is $redis->db->connection->url->password, 's3cret', 'password';

my @write;
$redis->on(connection => sub { my ($redis, $conn) = @_; @write = @{$conn->{write}} });

my $db = $redis->db;
my $err;
$db->connection->connect(sub { $err = $_[1]; Mojo::IOLoop->stop });
Mojo::IOLoop->start;
is_deeply \@write, [['AUTH s3cret'], ['SELECT 12']], 'write queue';

done_testing;
