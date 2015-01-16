package Zef;

use Mojo::Base qw<Mojolicious>;
use Zef::Plugins;
use Zef::Routing;
use Zef::Auth;
use DBI;

has db => sub {
  my $self = shift;
  return DBI->connect(
    $self->config->{'db'}->{'connection'},
    $self->config->{'db'}->{'username'},
    $self->config->{'db'}->{'password'},
  );
};

sub startup {
  my $self = shift;
  my $r    = $self->routes;

  Zef::Plugins->setup($self);
  Zef::Routing->setup($self);
};

420;
