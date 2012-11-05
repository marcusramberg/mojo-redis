use warnings;
use strict;
use utf8;
use Test::More;
use Mojo::Redis;

plan skip_all => 'Setup $REDIS_SERVER' unless $ENV{REDIS_SERVER};
plan tests => 6;

binmode STDOUT, ':utf8'; # because of use utf8;

{
  my $redis = Mojo::Redis->new(server => $ENV{REDIS_SERVER});
  my $str = "æøå";

  print "# $str\n";
  is length $str, 3, 'input got the correct length';
  ok utf8::is_utf8($str), 'input $str is utf8';

  $redis->set(test => $str);
  $redis->get(test => sub {
    is $_[1], $str, 'got $str back';
    ok utf8::is_utf8($_[1]), 'output $str is utf8';
    Mojo::IOLoop->stop;
  });

  Mojo::IOLoop->start;

  my $s = $redis->subscribe('s1');

  $s->on(data => sub {
    my($s, $res) = @_;
    print "# ", join('|', @$res), "\n";
    $redis->publish(s1 => "data: $str") unless grep { /data:/ } @$res;
    if(grep { /data:/ } @$res) {
      is $res->[2], "data: $str", 's1 deliver unicode';
      ok utf8::is_utf8($res->[2]), 's1 $str is utf8';
      Mojo::IOLoop->stop;
    }
  });
  Mojo::IOLoop->start;
}
