package Zef::Routing;
use Zef::Auth;

sub setup {
  my (undef, $self) = @_;
  my $r             = $self->routes;

  $r->route('/')->to('Controller::Main#home');
  $r->route('/modules')->to('Controller::Main#modules');
}

{ 420 => 'everyday' };
