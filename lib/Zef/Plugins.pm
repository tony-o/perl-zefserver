package Zef::Plugins;
use Mojolicious::Plugin::Human;

sub setup {
  my (undef, $self) = @_;
  $self->plugin('authentication' => {
    session_key   => $Zef::prefs->{'session_key'},
    load_user     => \&Zef::Auth::load_user,
    validate_user => \&Zef::Auth::validate_user,
  });

  $self->plugin('Human');
  $self->plugin('RenderFile');

  $self->plugin('config' => {
    file => 'zef.conf'
  });
};

'420';
