use ExtUtils::MakeMaker;
WriteMakefile(
  NAME => 'Mojo::Redis2',
  ABSTRACT_FROM => 'lib/Mojo/Redis2.pm',
  VERSION_FROM => 'lib/Mojo/Redis2.pm',
  AUTHOR => 'Jan Henning Thorsen <jhthorsen@cpan.org>',
  LICENSE => 'perl',
  PREREQ_PM => {

  },
  BUILD_REQUIRES => {

  },
  META_MERGE => {
    resources => {
      license => 'http://dev.perl.org/licenses/',
      homepage => 'https://metacpan.org/release/Mojo-Redis2',
      bugtracker => 'https://github.com/marcusramberg/mojo-redis/issues',
      repository => 'https://github.com/marcusramberg/mojo-redis.git',
    },
  },
  test => {
    TESTS => 't/*.t',
  },
  #MIN_PERL_VERSION => 5.10,
  #EXE_FILES => ['bin/my-app'],
);
