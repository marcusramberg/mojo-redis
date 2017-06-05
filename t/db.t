use Mojo::Base -strict;
use Test::More;
use Mojo::Redis;

plan skip_all => 'TEST_ONLINE=redis://localhost' unless $ENV{TEST_ONLINE};

my $redis = Mojo::Redis->new($ENV{TEST_ONLINE});
my $db    = $redis->db;
my @res;

# Make sure we don't send commands if $db goes out of scope
$db->set(x => 123, sub { @res = @_[1, 2]; Mojo::IOLoop->stop });
undef $db;

# SET
$db = $redis->db;
$db->set($0 => 123, sub { @res = @_[1, 2]; Mojo::IOLoop->stop });
Mojo::IOLoop->start;
is_deeply \@res, ['', 'OK'], 'set';

# GET
$db->get($0 => sub { @res = @_[1, 2]; Mojo::IOLoop->stop });
Mojo::IOLoop->start;
is_deeply \@res, ['', '123'], 'get';

# DEL
$db->del($0 => sub { @res = @_[1, 2]; Mojo::IOLoop->stop });
Mojo::IOLoop->start;
is_deeply \@res, ['', 1], 'get';

done_testing;
