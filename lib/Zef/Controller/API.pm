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
use LWP::Simple;
use File::Copy;
use File::Find;
use Try::Tiny;

sub p {
  my ($s,$k,$e) = @_;
  try {
    my $d;
    try { 
      $d = decode_json($s->req->body);
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
    $s->render(json => {
      failure => 1,
      reason  => $_,
    });
    undef;
  };
}

sub module_info {
  my ($self) = @_;
  my $data;

  $data = p($self, ['module'], 'Please provide the module name you\'re searching for');
  return 1 if ref($data) ne 'HASH';
  my $sql  = 'select * from version where module = ?';
  $sql .= ' and version = ?' if defined $data->{version};
  $sql .= ' and author = ?' if defined $data->{auth};
  $sql .= ' order by date desc';
  my $stmt = $self->app->db->prepare($sql);
  my @args = $data->{module};
  CORE::push @args, $data->{version} if defined $data->{version};
  CORE::push @args, $data->{auth} if defined $data->{auth};
  $stmt->execute(@args);
  my @ret;
  my %pushed;
  while (my $row = $stmt->fetchrow_hashref) {
    next if defined $pushed{$row->{module}};
    $pushed{$row->{module}} = 1;

    CORE::push @ret, {
      'short-name' => $row->{module},
      'ver' => $row->{version},
      'auth' => $row->{author},
      'commit' => $row->{commit_id},
    };
  }
  $self->render(json => {
    success => 1,
    data => \@ret,
  });
  return 1;
}

sub register {
  my ($self) = @_;
  my $data;

  $data = p($self, ['username','password'], "Provide a username and password\n");
  return 1 if ref($data) ne 'HASH';
  my $stmt = $self->app->db->prepare('select count(username) from users where username = ?');
  $stmt->execute($data->{'username'});
  my $rowc = $stmt->fetchrow_array();

  if ($rowc) {
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

  return try {
    $stmt = $self->app->db->prepare('update users set uq = ? where username = ? and password = ?');
    $stmt->execute($key, $data->{'username'}, $pass);

    $self->render(json => {
      success => 1,
      newkey  => $key, 
    });
    1;
  } catch {
    $self->render(json => {
      failure => 1,
    });
    1;
  };
}

sub download {
  my ($self) = @_;
  my ($data);
  $data = p($self, ['name'], "Invalid request, need {name:<>}\n");
  return 1 if ref($data) ne 'HASH';

  my $stmt = $self->app->db->prepare('select id from packages where name = ? ' . (defined $data->{'version'} ? ' AND version = ? ' : '') . (defined $data->{'author'} ? ' AND owner = ?' : '') . ' ORDER BY ID desc');
  my @params = $data->{'name'},;
  push @params, $data->{'version'} if defined $data->{'version'};
  push @params, $data->{'author'} if defined $data->{'author'};

  $stmt->execute(@params);
  my ($id) = $stmt->fetchrow_array();

  my $dir;

  if (!(defined $id && $id ne '')) {
    $dir = fetch_upstream($data->{name}, $self);
    if (!defined( $dir ) || $dir eq '') {
      $self->render(json => {
        error => 'Couldn\'t find module or module/author/version combination',
      });
      return 1;
    }
  } else {
    $dir = $self->config->{'module_dir'} . $id;
  }

  
  my @files;
  find(
    sub { 
      return if -d;
      my $f = $File::Find::name;
      CORE::push @files, substr($File::Find::name, length $dir); 
    },
    $dir
  );

  $data = '';
  for my $file (@files) {
    next if $file =~ m/\.git/;
    my $buff = encode_base64(slurp($dir . $file), '');
    my $mode = (stat($dir . $file))[2];;
    $data .= "$mode:$file\r\n$buff\r\n";
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
  my $m = 0;
  my $d = tempdir();
  foreach my $file (split "\r\n", $data->{'data'}) {
    if ($i % 2 == 0) {
      ($m, $f) = split ':', $file, 2;
      $m = oct($m);
    } else {
      make_path($d . dirname($f));
      open my $fh, '>', $d . $f;
      print $fh decode_base64($file);
      close $fh;
      chmod $m, $d . $f;
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

  CORE::push @return, @{search_upstream($data->{query}, $self)};
  
  $self->render(json => [@return]);
  return 1;
}

sub search_upstream {
  my ($module, $self) = @_;
  my $data = decode_json(slurp($self->config->{'upstream_dir'} . '/ecosystem/provides.json'));
  
  my $modolos = $data->{modules};
  my @modules;
  foreach my $provides (keys %{$modolos}) {
    foreach my $p (@{$modolos->{$provides}->{provides}}) {
      next unless index(uc $p, uc $module) > -1;
      CORE::push @modules, { 
        name      => $provides,
        version   => 'git',
        owner     => $modolos->{$provides}->{author} || 'unknown',
        submitted => 'whenever',
      };
      last;
    }
  }

  return [@modules];
}

sub fetch_upstream {
  my ($module, $self) = @_;
  my $data = decode_json(slurp($self->config->{'upstream_dir'} . 'ecosystem/provides.json'));
  
  my $modolos = $data->{modules};
  my @modules;
  foreach my $provides (keys %{$modolos}) {
    return $self->config->{'upstream_dir'} . 'ecosystem/' . $modolos->{$provides}->{dir} if $provides eq $module;
  }
  return undef;
}

{ everday => 'shufflin' };
