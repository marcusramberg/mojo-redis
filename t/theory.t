#!/usr/bin/env perl
use Mojo::Base -base;
use Mojo::Util 'monkey_patch';
use Scalar::Util 'weaken';
use Test::More;

my $i = 1;

monkey_patch 'main', 'new' => sub { ok 1, "new() $i"; my $obj = Mojo::Base::new(@_); $::trap{$obj} = $i++; $obj; };
monkey_patch 'main', 'DESTROY' => sub { ok 1, "DESTROY() " . delete $::trap{$_[0]}; };

sub add_callback {
  my($self) = @_;

  weaken $self;
  $self->{protocol}{cb} = sub {
    $self->{parent}{cb}->();
    $self->{parent};
  };
}

{
  my $yay;
  my $parent = main->new;
  my $child = main->new;

  $parent->{cb} = sub { $yay = 42; };

  $parent->{child} = $child;
  $child->{parent} = $parent;
  weaken $child->{parent};
  $child->add_callback;

  is $child->{protocol}{cb}->(), $parent, 'got parent from cb()';
  is $yay, 42, 'parent cb was called';
}

is_deeply [values %::trap], [], 'no leakage' or diag join ' ', 'leak obj:', sort values %::trap;

done_testing;

__END__
This test is just for proving theories I have about why
Mojo::Redis and subscriptions might leak.
