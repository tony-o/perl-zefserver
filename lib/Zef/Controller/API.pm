package Zef::Controller::API;
use Mojo::Base qw<Mojolicious::Controller>;
use JSON::Tiny qw<decode_json>;
use Digest::SHA qw{sha256_hex};
use Try::Tiny;
use Data::Dumper;

sub p {
  my ($s) = @_;
  decode_json($s->req->{'content'}->{'asset'}->{'content'});
}

sub login {
  my $self = shift;
  
  my ($data);
  return 1 if try {
    try {
      $data = p($self);
    };
    die "Provide some JSON data\n" if !defined($data) || $data eq '';
    die "Provide a username and password\n"
      unless (defined $data->{'username'} && 
              defined $data->{'password'});
    0;
  } catch {
    chomp $_;
    $self->render(json => {
      failure => 1,
      reason  => $_
    });
  };

  my $stmt = $self->config->{'db'}->prepare('select count(*) from users where username = ? and password =?');
  my $pass = sha256_hex($data->{'password'} . $self->config->{'salt'}); 
  $stmt->execute($data->{'username'}, $pass);

  if ($stmt->fetchrow_array() != 1) {
    $self->render(json => {
      failure => 1,
      reason  => 'Couldn\'t find user/pass combo',
    });
    return 1;
  }

  my $key = sha256_hex(time . $self->config->{'session_key'});
  $stmt = $self->config->{'db'}->prepare('update users set uq = ? where username = ? and password = ?');
  $stmt->execute($key, $data->{'username'}, $pass);

  $self->render(json => {
    success => 1,
    newkey  => $key, 
  });
}

{ everday => 'shufflin' };
