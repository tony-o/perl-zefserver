package AnyEvent::HTTPD::REST::Router;
use v5;
use Data::Dumper;
use JSON::Tiny;
use Moose;
use re qw(is_regexp);

has 'routes' => (is => 'rw', isa => 'HashRef');

sub handle {
  my $s = shift;
  my $r = shift;
  my $q = shift;
  my $handled = 0;
  my $rc;
  for my $route (keys $s->routes) {
    if (($r ~~ qr{$route}) == 1) {
      $rc = $s->routes->{$route}->($q); 
      $handled++;
      last if $rc != 0;
    } elsif ($route eq $r) {
      $rc = $s->routes->{$route}->($q);
      $handled++;
      last if $rc != 0;
    }
  }
};

sub register {
  my $s = shift;
  my $d = shift;
  $s->routes({ }) if not defined $s->routes;
  for my $r (keys $d) {
    $s->routes->{$r} = $d->{$r};
  }
}

420;
