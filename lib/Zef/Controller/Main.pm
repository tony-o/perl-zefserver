package Zef::Controller::Main;
use Mojo::Base qw<Mojolicious::Controller>;
use Text::Markdown qw<markdown>;
use Digest::SHA qw{sha256_hex};
use File::Slurp qw<slurp>;
use HTTP::Request::Common;
use Cwd qw<abs_path>;
use Fcntl qw<:mode>;
use LWP::UserAgent;
use JSON::Tiny;
use Try::Tiny;
use Pod::Html;

sub home {
  my $self = shift;

  $self->stash(
    container => {
      title  => 'Main Street',
      active => '/',
    },
  );
}

sub modules {
  my $self = shift;
  my $stmt = $self->app->db->prepare('select p2.*, to_char(p2.submitted, \'DD Mon YYYY\') submitted from (select MAX(submitted), name, owner from packages group by name, owner) p1 left join (select packages.*, users.id uid from packages left join users on packages.owner = \'ZEF:\' || users.username) p2 on p2.submitted = p1.max and p2.name = p1.name order by p2.submitted desc limit 20;');

  my @data;

  $stmt->execute;
  while (my $hash = $stmt->fetchrow_hashref) {
    updatereadme($self, $hash);
    push @data, $hash;
  }

  $self->stash(
    container => {
      active => '/modules',
      data   => [@data],
    },
  );
}

sub module {
  my $self = shift;
  my $stmt = $self->app->db->prepare('select p2.*, to_char(p2.submitted, \'DD Mon YYYY\') submitted from (select MAX(submitted), name, owner from packages group by name, owner) p1 left join (select * from packages) p2 on p2.submitted = p1.max and p2.name = p1.name WHERE p2.name = ? and p2.owner = ?;');
  $stmt->execute($self->stash->{'module'}, $self->stash->{'author'});
  my $data = $stmt->fetchrow_hashref;
  if (defined $data) {
    updatereadme($self, $data);
  }
  my $warn;
  my $freq = $self->req->param('file');
  my $cfdr = $self->config->{module_dir} . '/' . cfname($data->{name});
  my $rfil;
  if (-f abs_path($cfdr . (defined $freq ? '/' . $freq : ''))) {
    $rfil = $freq;
    $freq .= '/..';
  }
  if (not -e abs_path($cfdr . (defined $freq ? '/' . $freq : ''))) {
    $warn = 'Directory requested does not exist or inaccessible: ' . $freq;
    undef $freq;
  }

  my (@sorted, @files, $fdata);
  try {
    @files = list_files(
              $self,
              $data->{name},
              $cfdr . (defined $freq ? "\/$freq" : ''),
             );
    @sorted = sort {
      return $a->{fname} cmp $b->{fname} 
        if S_ISDIR($a->{mode}) eq S_ISDIR($b->{mode});
      return -1 if S_ISDIR($a->{mode});
      return  1 if S_ISDIR($b->{mode});   
      return $a->{fname} cmp $b->{fname};
    } @files;


    map { $_->{isdir} = 1 if S_ISDIR($_->{mode}) } @sorted;
    
  } catch { 
    warn $_;
    $warn = 'Do not attempt this';
  };

  try {
    if (defined $rfil) {
      $fdata = read_file($self, $data->{name}, $cfdr . $rfil);
    }
  } catch {

  };


  $self->stash(
    container => {
      author => $self->stash->{'author'},
      module => $self->stash->{'module'},
      data   => $data,
      files  => \@sorted,
      fdata  => $fdata,
      active => '/modules',
      warn   => $warn,
      script => [
        '//cdnjs.cloudflare.com/ajax/libs/highlight.js/8.4/highlight.min.js',
        '/js/markdown.js',
        '/js/modulepagination.js',
      ],
      style  => [
        '//cdnjs.cloudflare.com/ajax/libs/highlight.js/8.4/styles/github.min.css',
      ],
    },
  );
}

sub profile {
  my $self = shift;
  if (!defined $self->session('user')) {
    $self->session(wanted => '/profile');
    $self->redirect_to('/getfresh');
    return;
  }
}

sub logout {
  my $self = shift;
  $self->session(user => undef);
  $self->redirect_to('/');
}

sub getfresh {
  my $self = shift;
  my $error;
  if (defined $self->req->param('user') && defined $self->req->param('pass')) {
    my $user = $self->req->param('user');
    my $pass = sha256_hex($self->req->param('pass') . $self->config->{'salt'});
    my $stmt = $self->app->db->prepare('select * from users where username = ? and password = ?');
    $stmt->execute($user, $pass);
    $user = $stmt->fetchrow_hashref;
    if (($user->{'id'} // 0) > 0) {
      $self->session(user => $user);
      if (defined $self->session('wanted') && $self->session('wanted') ne '/getfresh') {
        $self->session(wanted => undef); 
        $self->redirect_to($self->session('wanted'));
        return;
      }
      $self->redirect_to('/profile');
      return;
    }
    $error = 'User/pass not found.';
  }
  $self->stash(container => {
    active => '/getfresh',
    reason => $error,
  });
}


#HELPERZ
sub read_file {
  my ($self, $m, $d) = @_;
  $m = cfname($m);
  if (index(abs_path($d), $self->config->{module_dir} . '/' . $m) != 0) {
    die 'Do not attempt this';
  }
  slurp $d;
}

sub list_files {
  my ($self, $m, $d) = @_;
  $m = cfname($m);
  if (index(abs_path($d), $self->config->{module_dir} . '/' . $m) != 0) {
    die 'Do not attempt this';
  }
  opendir DIR, $d;
  my @files;
  while (my $file = readdir DIR) {
    next if $file =~ m/^\.{1,2}(git)?$/;
    my ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,
           $atime,$mtime,$ctime,$blksize,$blocks) = stat($d . '/' . $file);
    push @files, {
      fname => $file,
      mode  => $mode,
      size  => $size,
    };
  }
  closedir DIR;
  return @files;
}

sub cfname {
  my ($m) = @_;
  $m =~ s/:/-/g;
  $m =~ s/[^A-Za-z0-9\-\.]//g;
  return $m;
}

sub updatereadme {
  my ($self, $hash) = @_;
  #warn 'serving cached content' if  defined $hash->{'readme'} && $hash->{'readme'} ne '';
  return if defined $hash->{'readme'} && $hash->{'readme'} ne '';
  my $cnt = $self->config->{module_dir} . '/' . cfname($hash->{'name'}) . '/';
  if (-e $cnt . '/README.md') {
    try { 
      $cnt .= 'README.md';
      my $ua  = LWP::UserAgent->new;
      my $req = HTTP::Request->new(POST => 'https://api.github.com/markdown/raw');
      $req->header('Content-Type' => 'text/plain');
      $req->content("".slurp($cnt));
      my $res = $ua->request($req); 
      if ($res->is_success) {
        $hash->{'readme'} = $res->content;
        my $stmt = $self->app->db->prepare('update packages set readme = ? where id = ?');
        $stmt->execute($hash->{'readme'}, $hash->{'id'});
      }
    } catch {
      warn $_; 
    };
  } elsif (-e $cnt . '/README.pod') {
    try {
      my $data = pod2html($cnt . '/README.pod', '--noheader', '--index', '--quiet', '--noverbose', '--outfile=/tmp/' . $hash->{id});
      $data = slurp '/tmp/' . $hash->{id};
      my $stmt = $self->app->db->prepare('update packages set readme = ? where id = ?');
      $stmt->execute($data, $hash->{id});
    } catch {
      warn $_;
    }
  } elsif (-e "$cnt/README") {
    try {
      my $data = slurp "$cnt/README";
      $data = "<pre>$data</pre>";
      my $stmt = $self->app->db->prepare('update packages set readme = ? where id = ?');
      $stmt->execute($data, $hash->{id});
    }
  }
}

{ smoke => 'everyday' };
