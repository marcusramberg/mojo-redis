package Mojo::Redis::Schema;

=head1 NAME

Mojo::Redis::Schema - Work on redis data with a schema

=head1 SYNOPSIS

  package My::App::Model::User;
  use Mojo::Redis::Schema;

  namespace 'user';
  key 'login', lookup;
  key 'name';
  set 'friends' => 'My::App::Model::User';
  string 'about';

  # checks all datastructures defined above to make sure they
  # make sense and returns a true value. Will also clean out
  # all the keywords
  build;

  $user = My::App::Model::User->new;
  $user->login('Foo');
  $user->name('Doe');
  $user->about('Loooong');
  $user->about->append(' string);
  $user->friends->sadd($user2);
  $user->exec;

The above creates this redis structure:

  "id:user" = 1
  "user:1" = { login => "Foo", name => "Doe" };
  "user:1:friends" = [ 2 ]
  "user:1:about" = "Loooong string"
  "user:Foo:id" = 1

Find a user:

  $user = My::App::Model::User->find(1);
  $user = My::App::Model::User->find(login => 'Foo');

=head1 DESCRIPTION

=cut

use Mojo::Base -base;
use Mojo::Redis;

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut

1;