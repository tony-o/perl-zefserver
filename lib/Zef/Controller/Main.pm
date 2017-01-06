package Zef::Controller::Main;
use Mojo::Base qw<Mojolicious::Controller>;
use Text::Levenshtein::Damerau::XS qw/xs_edistance/;
use Text::Markdown qw<markdown>;
use Digest::SHA qw{sha256_hex};
use experimental 'smartmatch';
use File::Slurp qw<slurp>;
use HTTP::Request::Common;
use List::Util qw<sum>;
use Cwd qw<abs_path>;
use Text::ParseWords;
use Fcntl qw<:mode>;
use LWP::UserAgent;
use LWP::Simple;
use JSON::Tiny qw<decode_json>;
use File::Spec;
use Try::Tiny;
use Pod::Html;

our $LTIME;
our $X;

sub home {
  my $self = shift;
  my $top10 = {
    ordr => [qw<auth updt>],
    stmt => {
      auth => $self->app->db->prepare('select distinct owner, count(*) count from packages where owner <> \'not in meta\' and unavailable = 0 group by owner order by count desc limit 10'),
      updt => $self->app->db->prepare('select name, owner from packages where unavailable = 0 order by action desc limit 10'),
    },
    verb => {
      auth => 'Most contrib authors',
      updt => 'Recently updated',
    },
    heads => {
      auth => [qw<Owner Count>],
      updt => [qw<Name Owner>],
    },
  };

  for my $x (keys %{$top10->{stmt}}) {
    $top10->{stmt}->{$x}->execute;
  }

  $self->stash(
    container => {
      title  => 'Main Street',
      active => '/',
      top10  => $top10,
    },
  );
}

sub modules {
  my $self = shift;
  my $page = $self->param('page') || 0;
  my $size = 30;
  $page = $page ~~ /^\d+$/ ? $page * $size : 0;
  my $stmt = $self->app->db->prepare(<<ESQL
    select 
      *, 
      to_char(packages.submitted, \'DD Mon YYYY\') submitted, 
      to_char(packages.action, \'DD Mon YYYY\') as action 
    from
      packages
    where
      unavailable = 0
    order by 
      packages.action desc 
    limit $size
    offset $page;
ESQL
);
  my $cont = $self->app->db->prepare(<<ESQL
    select 
      count(*) c
    from
      packages
    where unavailable = 0
ESQL
);

  my @data;

  $stmt->execute;
  my $first = 0;
  while (my $hash = $stmt->fetchrow_hashref) {
    updatereadme($self, $hash);
    push @data, $hash;
  }

  $cont->execute;
  my $count = $cont->fetchrow_hashref;
  $count = $count->{c};

  $self->stash(
    container => {
      active => '/modules',
      data   => [@data],
      pages  => ($count / $size)
    },
  );
}

sub module {
  my $self = shift;
  my $stmt = $self->app->db->prepare('select p2.*, to_char(p2.submitted, \'DD Mon YYYY\') submitted from (select MAX(submitted), name, owner from packages group by name, owner) p1 left join (select * from packages) p2 on p2.submitted = p1.max and p2.name = p1.name WHERE p2.name = ? and p2.owner = ? and p2.unavailable = 0;');
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
      $fdata = read_file($self, $data->{name}, "$cfdr/$rfil");
    }
  } catch {
    warn $_;
  };

  if (defined $freq && -f "$cfdr/$freq") {
    my $x = rindex($freq, '/');
    if ($x > -1) {
      $freq = substr $freq, 0, $x;
    } else {
      $freq = '';
    }
  }

  $self->stash(
    container => {
      author => $self->stash->{'author'},
      module => $self->stash->{'module'},
      rfile  => fix_rel($rfil),
      data   => $data,
      files  => \@sorted,
      fdata  => $fdata,
      active => '/modules',
      warn   => $warn,
      fbase  => fix_rel($freq),
      script => [
        '//cdnjs.cloudflare.com/ajax/libs/highlight.js/9.3.0/highlight.min.js',
        '/js/markdown.js',
        '/js/modulepagination.js',
      ],
      style  => [
        '//cdnjs.cloudflare.com/ajax/libs/highlight.js/9.3.0/styles/github.min.css',
      ],
    },
  );
}

sub profile {
  our ($X, $LTIME);
  my $self = shift;
  my $prof = $self->param('author');

  update_meta($self);

  my %modules  = %{$X->{modules}};
  my @authored;
  my $stmt = $self->app->db->prepare('select * from packages where name = ? and unavailable = 0 limit 1;');
  for my $mod (keys %modules) {
    next unless exists 
      $modules{$mod}->{author} 
      && defined $modules{$mod}->{author} 
      && $modules{$mod}->{author} eq $prof;
    $stmt->execute($mod);
    my $data = $stmt->fetchrow_hashref;
    push @authored, {
      data   => $data,
      module => "$mod",
      mdd    => $modules{$mod},
    };
  }

  @authored = sort {
    my $as = $a->{data}->{action};
    my $bs = $b->{data}->{action};
    $bs cmp $as;
  } @authored;

  $self->stash(
    container => {
      author  => $prof,
      modules => \@authored,
    }
  );
}

sub search {
  our ($X, $LTIME);
  my $self = shift;
  my $search = $self->param('terms');
  my @terms = grep {!/^\s*$/} quotewords('\s+', 0, $search);
  my (@results, %scores, $max_reasons);

  update_meta($self);

  use Data::Dumper;
  my %modules = %{$X->{modules}};
  foreach my $mod (keys %modules) {
    foreach my $index (0..@terms-1) {
      $scores{$mod} = { module => $mod, reasons => [], scores => [], score => undef }  unless ref($scores{$mod}) eq 'HASH';
      my $e = index(lc($mod), lc($terms[$index]));
      my $mm = $scores{$mod};
      if ($e > -1) {
        push @{$mm->{reasons}}, 'Module name';
        push @{$mm->{scores}}, $e;
      }
      if (defined $modules{$mod}->{provides}) {
        for my $provides (0..@{$modules{$mod}->{provides}}) { 
          next unless defined $modules{$mod}->{provides}->[$provides];
          my $e = index(lc($modules{$mod}->{provides}->[$provides]), lc($terms[$index]));
          if ($e > -1) {
            push @{$mm->{reasons}}, 'Provides';
            push @{$mm->{scores}}, $e;
          }
        }
      }
    }
  }

  @results = grep { 0 < scalar(@{$scores{$_}->{scores}}) } keys %scores;

  @results = sort {
    my $as = $scores{$a}->{scores};
    my $bs = $scores{$b}->{scores};
    return length($a) <=> length($b) if $as->[0] == $bs->[0];
    return $a <=> $b if $as->[0] == $bs->[0];
    return $as->[0] <=> $bs->[0];
  } @results;
  @results = splice @results, 0, 50;
  my $stmt = $self->app->db->prepare('select *, to_char(packages.submitted, \'DD Mon YYYY\') submitted, to_char(packages.action, \'DD Mon YYYY\') as action from packages where name = ? and unavailable = 0 limit 1;');
  map { 
    $_ = $scores{$_}; 
    $stmt->execute($_->{module});
    $_->{data} = $stmt->fetchrow_hashref;
  } @results;
  
  $self->stash(
    container => {
      results => \@results,
      terms   => $search,
    }
  );
}

sub logout {
  my $self = shift;
  $self->session(user => undef);
  $self->redirect_to('/');
}

sub about {
  my $self = shift;
  $self->stash(
    container => { 
      active => '/about',
    }
  );
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
  if (-f $d) {
    $d = substr $d, 0, rindex($d, '/');
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

sub fix_rel { 
  my @x = File::Spec->splitdir(shift); 
  my $flg;
  for (my $y = 0; $y < @x; $y++) { 
    $flg = $x[$y] eq '..';
    splice @x, $y-1, 2 if $flg && $y > 0;
    splice @x, $y,   1 if $flg && $y == 0; 
    $y-- if $flg;
  } 
  use Data::Dumper;
  return '' if scalar(@x) == 0;
  join "/", @x; 
}

sub update_meta {
  our ($LTIME, $X);
  my ($self) = @_;
  return if defined $LTIME && time - $LTIME < 60 * 5;
  $X = decode_json slurp($self->config->{module_dir} . '/../provides.json'); 
  $LTIME = time;
}

sub checktravis {
  my ($self, $repo, $hash) = @_;

  my $str  = get("https://api.travis-ci.org/repositories$repo.json");
  my $json = try {
    decode_json $str;
  } || { error => "Not found" };
  use Data::Dumper; print Dumper $json;
  return 
  $json;
}

{ smoke => 'everyday' };
