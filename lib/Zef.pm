package Zef;

use Mojo::Base qw<Mojolicious>;
use Zef::Plugins;
use Zef::Routing;
use Zef::Auth;

sub startup {
  my $self = shift;
  my $r    = $self->routes;

  Zef::Plugins->setup($self);
  Zef::Routing->setup($self);
};

420;
