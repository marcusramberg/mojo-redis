use Mojo::Base -strict;
use Test::More;
use Mojo::Redis;

use Test::Memory::Cycle;

plan skip_all => 'TEST_ONLINE=redis://localhost' unless $ENV{TEST_ONLINE};

my $redis = Mojo::Redis->new($ENV{TEST_ONLINE});
my $db    = $redis->db;
memory_cycle_ok($redis, 'cycle ok for Mojo::Redis');

my $pubsub = $redis->pubsub;
my (@messages, @res);
memory_cycle_ok($redis, 'cycle ok for Mojo::Redis::PubSub');

is ref($pubsub->listen(rtest1 => sub { push @messages, $_[1] })), 'CODE', 'listen';
$pubsub->listen(rtest2 => sub { push @messages, $_[1]; Mojo::IOLoop->stop; });
memory_cycle_ok($redis, 'cycle ok after listen');

# Not a good solution to run a timer, but that's what I have for now
Mojo::IOLoop->timer(0.2 => sub { Mojo::IOLoop->stop });
Mojo::IOLoop->start;

$pubsub->notify(rtest1 => '123');
$db->publish(rtest2 => 'stopping');
memory_cycle_ok($redis, 'cycle ok after notify');
Mojo::IOLoop->timer(2 => sub { Mojo::IOLoop->stop });    # guard
Mojo::IOLoop->start;

is $pubsub->unlisten('rtest1'), $pubsub, 'unlisten';
memory_cycle_ok($pubsub, 'cycle ok after unlisten');
$db->publish(rtest1 => 42);

is_deeply \@messages, ['123', 'stopping'], 'got notified';

my $conn = $pubsub->connection;
is @{$conn->subscribers('message')}, 1, 'only one message subscriber';

undef $pubsub;
undef $redis->{pubsub};
isnt $redis->db->connection, $conn, 'pubsub connection cannot be re-used';

done_testing;
