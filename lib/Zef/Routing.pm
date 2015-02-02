package Zef::Routing;
use Zef::Auth;

sub setup {
  my (undef, $self) = @_;
  my $r             = $self->routes;
  my $api           = $r->route('api');

  $r->route('/')->to('Controller::Main#home');
  $r->route('/modules')->to('Controller::Main#modules');
  $r->route('/modules/#author/#module')->to('Controller::Main#module');
  $r->route('/login')->to('Controller::Main#login');
  $r->route('/register')->to('Controller::Main#register');

  $api->route('/login')->to('Controller::API#login');
  $api->route('/register')->to('Controller::API#register');
  $api->route('/push')->to('Controller::API#push');
  $api->route('/search')->to('Controller::API#search');
  $api->route('/download')->to('Controller::API#download');
}

{ 420 => 'everyday' };
