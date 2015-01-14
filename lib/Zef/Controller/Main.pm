package Zef::Controller::Main;
use Mojo::Base qw<Mojolicious::Controller>;

sub home {
  my $self = shift;

  $self->stash(
    container => {
      data => { title => 'Main Street', },
    },
  );

  $self->render;#template => 'controller/content/main');
}

{ smoke => 'everyday' };
