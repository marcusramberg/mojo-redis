package Mojo::Redis2;

=head1 NAME

Mojo::Redis2 - Pure-Perl non-blocking I/O Redis driver

=head1 VERSION

0.01

=head1 DESCRIPTION

L<Mojo::Redis2> is a pure-Perl non-blocking I/O L<Redis|http://redis.io>
driver for the L<Mojolicious> real-time framework.

=head1 SYNOPSIS

  use Mojo::Redis2;
  my $redis = Mojo::Redis2->new;

=cut

use Mojo::Base -base;
use constant DEBUG => $ENV{MOJO_REDIS_DEBUG} || 0;

our $VERSION = '0.01';

=head1 ATTRIBUTES

=head1 METHODS

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014, Jan Henning Thorsen

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut

1;
