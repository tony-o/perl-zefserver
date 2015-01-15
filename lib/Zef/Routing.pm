package Zef::Routing;
use Zef::Auth;

sub setup {
  my (undef, $self) = @_;
  my $r             = $self->routes;
  my $api           = $r->route('api');

  $r->route('/')->to('Controller::Main#home');
  $r->route('/modules')->to('Controller::Main#modules');

  $api->route('/login')->to('Controller::API#login');
  $api->route('/register')->to('Controller::API#register');
}

{ 420 => 'everyday' };
