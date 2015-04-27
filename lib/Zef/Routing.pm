package Zef::Routing;
use Zef::Auth;

sub setup {
  my (undef, $self) = @_;
  my $r             = $self->routes;
  my $api           = $r->route('api');

  $r->route('/')->to('Controller::Main#home');
  $r->route('/modules')->to('Controller::Main#modules');
  $r->route('/modules/#author/#module')->to('Controller::Main#module');
  $r->route('/getfresh')->to('Controller::Main#getfresh');
  $r->route('/profile')->to('Controller::Main#profile');
  $r->route('/logout')->to('Controller::Main#logout');

  $api->route('/login')->to('Controller::API#login');
  $api->route('/register')->to('Controller::API#register');
  $api->route('/push')->to('Controller::API#push');
  $api->route('/search')->to('Controller::API#search');
  $api->route('/download')->to('Controller::API#download');
  $api->route('/fetch_upstream')->to('Controller::API#search_upstream');
}

{ 420 => 'everyday' };
