package Zef::Controller::API;
use Mojo::Base qw<Mojolicious::Controller>;
use JSON::Tiny qw<decode_json>;
use Digest::SHA qw{sha256_hex};
use File::Path qw{make_path};
use File::Temp qw{tempdir};
use File::Basename;
use Data::Dumper;
use MIME::Base64;
use File::Copy;
use Try::Tiny;

sub p {
  my ($s) = @_;
  decode_json($s->req->{'content'}->{'asset'}->{'content'});
}

sub register {
  my ($self) = @_;
  my ($data);
  return 1 if try {
    try {
      $data = p($self);
      die $data;
    };
    die "Provide some JSON data\n" if !defined($data) || $data eq '';
    die "Provide a username and password\n"
      unless (defined $data->{'username'} && 
              defined $data->{'password'});
    0;
  } catch {
    chomp $_;
    die $_;
    $self->render(json => {
      failure => 1,
      reason  => $_
    });
    1;
  };
  my $stmt = $self->config->{'db'}->prepare('select count(username) from users where username = ?');
  $stmt->execute($data->{'username'});
  my $rowc = $stmt->fetchrow_array();
  if ($rowc != 0) {
    $self->render(json => {
      failure => 1,
      reason  => 'Username already in use',
    });
    return 1;
  }
  $stmt = $self->config->{'db'}->prepare('insert into users (username, password, uq) values (?,?,?)');
  my $key = sha256_hex(time . $self->config->{'session_key'});
  my $pas = sha256_hex($data->{'password'} . $self->config->{'salt'});
  $stmt->execute($data->{'username'}, $pas, $key);
  $self->render(json => {
    success => 1,
    newkey  => $key,
  });
  return 1;
}

sub login {
  my ($self) = @_;
  
  my ($data);
  return 1 if try {
    try {
      $data = p($self);
      die $data;
    };
    die "Provide some JSON data\n" if !defined($data) || $data eq '';
    die "Provide a username and password\n"
      unless (defined $data->{'username'} && 
              defined $data->{'password'});
    0;
  } catch {
    chomp $_;
    die $_;
    $self->render(json => {
      failure => 1,
      reason  => $_
    });
    1;
  };

  my $stmt = $self->config->{'db'}->prepare('select count(*) from users where username = ? and password =?');
  my $pass = sha256_hex($data->{'password'} . $self->config->{'salt'}); 
  $stmt->execute($data->{'username'}, $pass);
  my ($cnt) = $stmt->fetchrow_array();
  if ($cnt != 1) {
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

sub push {
  my ($self) = @_;
  my ($data);
  return 1 if try {
    try {
      $data = p($self);
    };
    die "Provide some JSON data\n" if !defined($data) || $data eq '';
    die "Invalid request, need {key:<>,meta:{},data:{}}\n"
      unless (defined $data->{'key'} && 
              defined $data->{'meta'} &&
              defined $data->{'data'});
    0;
  } catch {
    chomp $_;
    $self->render(json => {
      failure => 1,
      reason  => $_
    });
    1;
  };
  my $stmt = $self->config->{'db'}->prepare('select id,username from users where uq = ?');
  $stmt->execute($data->{'key'});
  my ($id,$user) = $stmt->fetchrow_array();

  if (! (defined $id && $id ne '')) {
    $self->render(json => {
      error => 'Couldn\'t find user with that session key',
    });
    return 1;
  }
  if (! defined $data->{'meta'}->{'version'}) {
    $self->render(json => {
      error => 'Please supply a version # in your META',
    });
    return 1;
  }
  $stmt = $self->config->{'db'}->prepare('select id from packages where name = ? and owner = ? and version = ?');
  $stmt->execute($data->{'meta'}->{'name'}, "ZEF:$user", $data->{'meta'}->{'version'});
  my ($pkgid) = $stmt->fetchrow_array();
  if (defined $pkgid && $pkgid ne '') {
    $self->render(json => {
      error => 'This version from you already exists, bump your version #',
    });
    return 1;
  }
  my $version = $data->{'meta'}->{'version'};
  my $i = 0;
  my $f = 0;
  my $d = tempdir();
  foreach my $file (split "\r\n", $data->{'data'}) {
    if ($i % 2 == 0) {
      $f = $file;
    } else {
      make_path($d . dirname($f));
      open my $fh, '>', $d . $f;
      print $fh, decode_base64($file);
      close $fh;
    }
    $i++;
  }

  make_path($self->config->{'module_dir'}) or die 'Set module_dir in zef.conf';

  my $depends = defined $data->{'meta'}->{'dependencies'} 
                  ? j($data->{'meta'}->{'dependencies'}) 
                  : '{}';
  my $stmt1 = $self->config->{'db'}->prepare('insert into packages (name,owner,dependencies,version,repo) values (?, ?, ?, ?, ?)');
  my $stmt2 = $self->config->{'db'}->prepare('select id from packages where name = ? and owner = ? and version = ?');

  $stmt1->execute(
    $data->{'meta'}->{'name'},
    "ZEF:$user",
    $depends,
    $data->{'meta'}->{'version'},
    defined $data->{'meta'}->{'repository'}
      ? $data->{'meta'}->{'repository'}
      : defined $data->{'meta'}->{'support'} && defined $data->{'meta'}->{'support'}->{'source-url'}
        ? $data->{'meta'}->{'support'}->{'source-url'}
        : ''
  );
  $stmt2->execute(
    $data->{'meta'}->{'name'},
    "ZEF:$user",
    $data->{'meta'}->{'version'},
  );
  ($id) = $stmt2->fetchrow_array();
  move($d, $self->config->{'module_dir'} . "/$id/");

  $self->render(json => {
    success => 1,
    version => $version,
  });
  return 1;
}

{ everday => 'shufflin' };
