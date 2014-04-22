package t::LeakTrap;

use Mojo::Base -strict;
use Mojo::Redis;
use Mojo::Util 'monkey_patch';
use Test::More;

sub import {
  my $class = shift;

  my $DESTROY = \&Mojo::Redis::DESTROY;
  my $i = 0;

  monkey_patch 'Mojo::Redis', 'new' => sub { diag "new() $i"; my $obj = Mojo::Base::new(@_); $::trap{$obj} = $i++; $obj; };
  monkey_patch 'Mojo::Redis', 'DESTROY' => sub { diag "DESTROY() ", delete $::trap{$_[0]}; $DESTROY->(@_); };

  strict->import;
  warnings->import;
}

1;
