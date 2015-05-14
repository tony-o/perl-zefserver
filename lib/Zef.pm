package Zef;

use Mojo::Base qw<Mojolicious>;
use Zef::Plugins;
use Zef::Routing;
use Zef::Auth;
use Mojo::Pg;

sub db {
  my $self = shift;
  state $connection = DBI->connect(
    ( "dbi:Pg:dbname="
    . $self->config->{'db'}->{'db_name'}
    . ';host='
    . $self->config->{'db'}->{'host'} . ";"),
    $self->config->{'db'}->{'username'},
    $self->config->{'db'}->{'password'}
  );
};

sub startup {
  my $self = shift;
  my $r    = $self->routes;

  Zef::Plugins->setup($self);
  Zef::Routing->setup($self);
};

420;
