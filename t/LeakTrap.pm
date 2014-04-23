package t::LeakTrap;

use Mojo::Base -strict;
use Mojo::Redis;
use Mojo::Util 'monkey_patch';
use Test::More;

sub import {
  my $class = shift;

  my $DESTROY = \&Mojo::Redis::DESTROY;
  my $i = 1;

  monkey_patch 'Mojo::Redis', 'new' => sub { ok 1, "new() $i"; my $obj = Mojo::Base::new(@_); $::trap{$obj} = $i++; $obj; };
  monkey_patch 'Mojo::Redis', 'DESTROY' => sub { $DESTROY->(@_); ok 1, "DESTROY() " . delete $::trap{$_[0]}; };

  strict->import;
  warnings->import;
}

1;
