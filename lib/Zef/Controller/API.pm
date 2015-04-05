package Zef::Controller::API;
use Mojo::Base qw<Mojolicious::Controller>;
use JSON::Tiny qw<decode_json>;
use Digest::SHA qw{sha256_hex};
use File::Path qw{make_path};
use File::Temp qw{tempdir};
use File::Slurp qw{slurp};
use File::Basename;
use Data::Dumper;
use MIME::Base64;
use File::Copy;
use File::Find;
use Try::Tiny;

sub p {
  my ($s,$k,$e) = @_;
  try {
    my $d;
    try { 
      $d = decode_json($s->req->{'content'}->{'asset'}->{'content'});
    };
    die "Provide some JSON data\n" if ! defined($d) || $d eq '';
    map {
      die $e if ! defined $d->{$_};
      1;
    } @{$k};
    $d;
  } catch {
    chomp $_;
    warn  $_;
    warn 'sending json';
    $s->render(json => {
      failure => 1,
      reason  => $_,
    });
    warn 'return undef';
    undef;
  };
}

sub register {
  my ($self) = @_;
  my $data;

  $data = p($self, ['username','password'], "Provide a username and password\n");
  return 1 if ref($data) ne 'HASH';
  warn Dumper $data; 
  my $stmt = $self->app->db->prepare('select count(username) from users where username = ?');
  $stmt->execute($data->{'username'});
  my $rowc = $stmt->fetchrow_array();
  if ($rowc != 0) {
    $self->render(json => {
      failure => 1,
      reason  => 'Username already in use',
    });
    return 1;
  }
  $stmt = $self->app->db->prepare('insert into users (username, password, uq) values (?,?,?)');
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
  $data = p($self, ['username','password'], "Provide a username and password\n");
  return 1 if ref($data) ne 'HASH';

  my $pass = sha256_hex($data->{'password'} . $self->config->{'salt'}); 
  my $stmt = $self->app->db->prepare('select count(*) from users where username = ? and password = ?');
  $stmt->execute($data->{'username'}, $pass);
  my ($cnt) = $stmt->fetchrow_array();
  if ($cnt != 1) {
    $self->render(json => {
      failure => 1,
      reason  => 'Couldn\'t find user/pass combo', #. $DBI::errstr,
    });
    return 1;
  }

  my $key = sha256_hex(time . $self->config->{'session_key'});
  $stmt = $self->app->db->prepare('update users set uq = ? where username = ? and password = ?');
  $stmt->execute($key, $data->{'username'}, $pass);

  $self->render(json => {
    success => 1,
    newkey  => $key, 
  });
}

sub download {
  my ($self) = @_;
  my ($data);
  $data = p($self, ['name'], "Invalid request, need {name:<>}\n");
  return 1 if ref($data) ne 'HASH';

  my $stmt = $self->app->db->prepare('select id from packages where name = ? ' . (defined $data->{'version'} ? ' AND version = ? ' : '') . (defined $data->{'author'} ? ' AND owner = ?' : ''));
  my @params = $data->{'name'},;
  push @params, $data->{'version'} if defined $data->{'version'};
  push @params, $data->{'author'} if defined $data->{'author'};

  $stmt->execute(@params);
  my ($id) = $stmt->fetchrow_array();

  if (!(defined $id && $id ne '')) {
    $self->render(json => {
      error => 'Couldn\'t find module or module/author/version combination',
    });
    return 1;
  }

  my @files;
  find(
    sub { 
      return if -d;
      my $f = $File::Find::name;
      CORE::push @files, substr($File::Find::name, length $self->config->{'module_dir'} . $id); 
    },
    $self->config->{'module_dir'} . $id
  );

  $data = '';
  for my $file (@files) {
    my $buff = encode_base64(slurp($self->config->{'module_dir'} . $id . $file), '');
    $data .= "$file\r\n$buff\r\n";
  }
  $self->render(text => $data);
}

sub push {
  my ($self) = @_;
  my ($data);

  $data = p($self, ['key','meta','data'], "Invalid request, need {key:<>,meta:{},data{}}\n");
  return 1 if ref($data) ne 'HASH';
  
  my $stmt = $self->app->db->prepare('select id,username from users where uq = ?');
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
  $stmt = $self->app->db->prepare('select id from packages where name = ? and owner = ? and version = ?');
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
      print $fh decode_base64($file);
      close $fh;
    }
    $i++;
  }

  die 'Set module_dir in zef.conf' unless defined $self->config->{'module_dir'};
  make_path($self->config->{'module_dir'}); 

  my $depends = defined $data->{'meta'}->{'dependencies'} 
                  ? j($data->{'meta'}->{'dependencies'}) 
                  : '{}';
  my $stmt1 = $self->app->db->prepare('insert into packages (name,owner,dependencies,version,repo) values (?, ?, ?, ?, ?)');
  my $stmt2 = $self->app->db->prepare('select id from packages where name = ? and owner = ? and version = ?');

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

sub search {
  my ($self) = @_;
  my ($data);
  
  $data = p($self, ['query'], "Invalid request, need {query:<>}\n");
  return 1 if ref($data) ne 'HASH';

  my $stmt = $self->app->db->prepare('select p2.* from (select MAX(submitted), name, owner from packages group by name, owner) p1 left join (select * from packages) p2 on p2.submitted = p1.max and p2.name = p1.name WHERE upper(p2.name) like upper(?) or upper(p2.owner) like upper(?);');
  $stmt->execute('%' . $data->{'query'} . '%', '%' . $data->{'query'} . '%');
  my @return;
  while (my $row = $stmt->fetchrow_hashref) {
    CORE::push @return, {
      name      => $row->{'name'},
      owner     => $row->{'owner'},
      version   => $row->{'version'},
      submitted => $row->{'submitted'},
    };
  }

  $self->render(json => [@return]);
  return 1;
}

{ everday => 'shufflin' };
