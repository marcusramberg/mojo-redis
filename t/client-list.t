use Test::More;
use t::LeakTrap;

plan skip_all => 'Set REDIS_SERVER=127.0.0.1:6379' unless $ENV{REDIS_SERVER};

my $redis = Mojo::Redis->new(server => "redis://$ENV{REDIS_SERVER}/14", timeout => 5);

{
  my $clients = $redis->client_list;
  my ($name) = grep { $clients->{$_}{self} } keys %$clients;

  like $name, qr{^[\w\.]+:\d+$}, 'got addr:port';
  ok $clients->{$name}{cmd}, 'got cmd';
  is $clients->{$name}{idle}, 0, 'got idle';
  ok $clients->{$name}{db}, 'got db';
  ok $clients->{$name}{fd}, 'got fd';
}

{
  my $redis = Mojo::Redis->new(server => "redis://$ENV{REDIS_SERVER}/14", timeout => 5);
  my $clients;
  $redis = $redis->client_list(sub { $clients = $_[1]; Mojo::IOLoop->stop; });
  Mojo::IOLoop->start;
  ok +(keys %$clients) >= 2, 'two or more clients' or diag join '|', keys %$clients;
  ok $redis->isa('Mojo::Redis'), 'client_list($cb) return $redis';
  my @names = grep { $clients->{$_}{self} } keys %$clients;
  is @names, 1, 'only one client is self';
  like $names[0], qr{^[\w\.]+:\d+$}, 'got addr:port nb';
  ok $clients->{$names[0]}{self}, 'got self';
}

undef $redis;

is_deeply [values %::trap], [], 'no leakage' or diag join ' ', 'leak obj:', sort values %::trap;

done_testing;
