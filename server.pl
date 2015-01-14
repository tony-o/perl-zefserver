#!/usr/bin/env perl

use lib 'lib';
use v5;
use Digest::SHA qw{sha256_hex};
use File::Path qw{make_path};
use File::Temp qw{tempdir};
use File::Slurp qw{slurp};
use JSON::Tiny qw{j};
use Text::Handlebars;
use Cwd qw{abs_path};
use AnyEvent::HTTPD;
use File::Basename;
use MIME::Base64;
use Data::Dumper;
use Mojolicious;
use File::Copy;
use Try::Tiny;
use DBI;

my $prefst     = slurp 'prefs.json';
my $prefs      = j($prefst);
my $server     = AnyEvent::HTTPD->new (
                   port => $prefs->{'port'} || 9000,
                 );
my $router     = AnyEvent::HTTPD::REST::Router->new;
my $handlebars = Text::Handlebars->new();
my $dbh;
my %preps;
my %cache;

sub reconnect {
  return if (defined $dbh && $dbh->ping); 
  $dbh = DBI->connect($prefs->{'db'}->{'db'}, $prefs->{'db'}->{'user'}, $prefs->{'db'}->{'pass'}) || die 'couldn\'t connect to db';
  undef %preps;
}

$router->register({
  ('^' . $prefs->{'base'} . '/login$') => sub{ 
    reconnect;
    my $req = shift;
    my $data;
    try { $data = j($req->content); } catch { undef $data; }; 
    if (not defined $data) {
      $req->respond([200, 'dumbass', {'Content-Type' => 'application/json'}, j({failure => 1, reason => 'Send some POST data'})]);
      return 1;
    }
    if (!defined $data->{'username'} || !defined $data->{'password'}) {
      $req->respond([200, 'dumbass', {'Content-Type' => 'application/json'}, j({failure => 1, reason => 'Give us a user/pass'})]);
      return 1;
    }

    if (!defined $preps{'login'}) {
      $preps{'login'} = $dbh->prepare('select count(username) from users where username = ? and password = ?');
    }
    my $pass = sha256_hex($data->{'password'} . $prefs->{'salt'});
    $preps{'login'}->execute($data->{'username'}, $pass);
    if ($preps{'login'}->fetchrow_array() != 1) {
      $req->respond([200, 'ok', {'Content-Type' => 'application/json'}, j({failure => 1, reason => 'Couldn\'t find user/pass combo'})]);
      return 1;
    }
  
    if (!defined $preps{'setuserkey'}) {
      $preps{'setuserkey'} = $dbh->prepare('update users set uq = ? where username = ? and password = ?');
    }
    my $nk = sha256_hex(time . $prefs->{'sessionkey'});
    $preps{'setuserkey'}->execute($nk, $data->{'username'}, $pass);
  
    $req->respond([200, 'ok', {'Content-Type' => 'application/json'}, j({success => 1, newkey => $nk})]);
    return 1;
  },
  ('^' . $prefs->{'base'} . '/testresult$') => sub {
    reconnect;
    my $req = shift;
    my $data; 
    try { $data = j($req->content); } catch { undef $data; }; 
    if (not defined $data) {
      $req->respond([200, 'dumbass', {'Content-Type' => 'application/json'}, j({failure => 1, reason => 'Send some POST data'})]);
      return 1;
    }
    my @requiredfields = qw{package results os perlversion moduleversion};
    my $flag = 0;
    for my $qq (@requiredfields) { 
       $flag++ if not defined $data->{$qq};
       last if $flag > 0;
    };
    if ($flag > 0) {
      $req->respond([200, 'dumbass', {'Content-Type' => 'application/json'}, j({error => 'Please supply all required fields: ' . join(', ', @requiredfields)})]);
      return 1;
    }

    my $username = '*';
    if (defined $data->{'tester'} && ($data->{'tester'} ~~ qr{^[a-fA-F0-9]{64}$}) == 1) {
      if (not defined $preps{'fetchusername'}) {
        $preps{'fetchusername'} = $dbh->prepare('select username from users where uq = ?');
      }
      $preps{'fetchusername'}->execute($data->{'tester'});
      $username = $preps{'fetchusername'}->fetchrow_array();
      $username = '*' if $username eq '';
      $username = "ZEF:$username" if $username ne '*';
    }

    my $module = $data->{'package'};
    my $version;
    if (defined $data->{'moduleversion'} && ($data->{'moduleversion'} ~~ qr{^[a-fA-F0-9]{40,64}$}) == 1) {
      if (not defined $preps{'fetchmoduleversion'}) {
        $preps{'fetchmoduleversion'} = $dbh->prepare('select version from packages where name = ? and commit = ?');
      }
      $preps{'fetchmoduleversion'}->execute($module, $data->{'moduleversion'});
      $version = $preps{'fetchmoduleversion'}->fetchrow_array();
      if ($version eq '') {
        $req->respond([200, 'dumbass', {'Content-Type' => 'application/json'}, j({error => 'Module commit ID is required to lookup module version'})]);
        return 1;
      }
    } else {
      $req->respond([200, 'dumbass', {'Content-Type' => 'application/json'}, j({error => 'Module commit ID is required to lookup module version'})]);
      return 1;
    }

    my $rawdata = j({results => $data->{'results'}, perlversion => $data->{'perlversion'}, os => $data->{'os'}});
    if (not defined $preps{'submittestresult'}) {
      $preps{'submittestresult'} = $dbh->prepare('insert into tests (user,module,version,testdata) values (?,?,?,?)');
    }
    $preps{'submittestresult'}->execute($username, $module, $version, $rawdata);
    $req->respond([200, 'dumbass', {'Content-Type' => 'application/json'}, j({success => 1})]);
    return 1;
  },
  ('^' . $prefs->{'base'} . '/register$') => sub {
    reconnect;
    my $req = shift;
    my $data;
    try { $data = j($req->content); } catch { undef $data; }; 
    if (not defined $data) {
      $req->respond([200, 'dumbass', {'Content-Type' => 'application/json'}, j({failure => 1, reason => 'Send some POST data'})]);
      return 1;
    }
    my $user = $data->{'username'};
    my $pass = sha256_hex($data->{'password'} . $prefs->{'salt'});

    if (not defined $preps{'checkusernameavail'}) {
      $preps{'checkusernameavail'} = $dbh->prepare('select count(username) from users where username = ?');
    }
    $preps{'checkusernameavail'}->execute($user);
    my $rowc = $preps{'checkusernameavail'}->fetchrow_array();
    if ($rowc != 0) {
      $req->respond([200, 'dumbass', {'Content-Type' => 'application/json'}, j({failure => 1, reason => 'Username already in use'})]);
      return 1;
    }
    
    if (not defined $preps{'newuser'}) {
      $preps{'newuser'} = $dbh->prepare('insert into users (username, password, uq) values  (?, ?, ?)');
    }
    my $uk = sha256_hex(time . $prefs->{'sessionkey'});
    $preps{'newuser'}->execute($user, $pass, $uk);

    $req->respond([200, 'dumbass', {'Content-Type' => 'application/json'}, j({success => 1, newkey => $uk})]);
    return 1;
  },
  ('^' . $prefs->{'base'} . '/push$') => sub {
    reconnect;
    my $req = shift;
    my $data;
    try { $data = j($req->content); } catch { undef $data; }; 
    if (not defined $data) {
      $req->respond([200, 'dumbass', {'Content-Type' => 'application/json'}, j({failure => 1, reason => 'Send some POST data'})]);
      return 1;
    }
    if (! ( defined $data->{'key'} && defined $data->{'meta'} && defined $data->{'data'}) ) {
      $req->respond([200, 'dumbass', {'Content-Type' => 'application/json'}, j({failure => 1, reason => 'Invalid request..need {key:<>, meta:{}, data:{}}'})]);
      return 1;
    }
    if (not defined $preps{'getuseridwkey'}) {
      $preps{'getuseridwkey'} = $dbh->prepare('select id, username from users where uq = ?');
    }
    $preps{'getuseridwkey'}->execute($data->{'key'});
    my ($id, $user) = $preps{'getuseridwkey'}->fetchrow_array();
    if (not defined $id || $id ne '') {
      $req->respond([200, 'dumbass', {'Content-Type' => 'application/json'}, j({error => 'Couldn\'t find user with specified key'})]);
      return 1;
    }
    if (not defined $data->{'meta'}->{'version'}) {
      $req->respond([200, 'dumbass', {'Content-Type' => 'application/json'}, j({error => 'Please supply a version # in your META'})]);
      return 1;
    }
    if (not defined $preps{'idgrab'}) {
      $preps{'idgrab'} = $dbh->prepare('select id from packages where name = ? and owner = ? and version = ?');
    }
    $preps{'idgrab'}->execute($data->{'meta'}->{'name'}, "ZEF:$user", $data->{'meta'}->{'version'});
    my ($id) = $preps{'idgrab'}->fetchrow_array();
    if (defined $id || $id ne '') {
      $req->respond([200, 'dumbass', {'Content-Type' => 'application/json'}, j({error => 'This version from you already exists, bump your version #'})]);
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
        open(my $fh, '>', $d . $f);
        print $fh decode_base64($file);
        close $fh;
      }
      $i++;
    }
    make_path("./modules");
    my $depends = defined $data->{'meta'}->{'dependencies'} ? j($data->{'meta'}->{'dependencies'}) : '{}';
    if (not defined $preps{'addpackage'}) {
      $preps{'addpackage'} = $dbh->prepare('insert into packages (name, owner, dependencies, version, repo) values (?, ?, ?, ?, ?)');
      $preps{'idgrab'}     = $dbh->prepare('select id from packages where name = ? and owner = ? and version = ?');
    }
    $preps{'addpackage'}->execute(
      $data->{'meta'}->{'name'}, 
      "ZEF:$user", 
      $depends, 
      $version, 
      defined $data->{'meta'}->{'repository'} ? $data->{'meta'}->{'repository'} : defined $data->{'meta'}->{'support'} && defined $data->{'meta'}->{'support'}->{'source-url'} ?  $data->{'meta'}->{'support'}->{'source-url'} : '', 
    );
    $preps{'idgrab'}->execute($data->{'meta'}->{'name'}, "ZEF:$user", $version);
    ($id) = $preps{'idgrab'}->fetchrow_array();
    move($d, "./modules/$id/");

    $req->respond([200, 'dumbass', {'Content-Type' => 'application/json'}, j({latestcommit => $commit, version => $version})]);
    return 1;
  },
  ('^' . $prefs->{'base'} . '/search$') => sub {
    reconnect;
    my $req = shift;
    my $data;
    try { $data = j($req->content); } catch { undef $data; }; 
    if (not defined $data) {
      $req->respond([200, 'dumbass', {'Content-Type' => 'application/json'}, j({failure => 1, reason => 'Send some POST data'})]);
      return 1;
    }
    if (not defined $data->{'query'}) {
      $req->respond([200, 'dumbass', {'Content-Type' => 'application/json'}, j({failure => 1, reason => '{query:<>} required and not found'})]);
      return 1;
    }
    my $paged = defined $data->{'page'} && $data->{'page'} ~~ qr{^\d+$} ? $data->{'page'} * 50 : 0;
    if (not defined $preps{'pagedsearch'}) {
      $preps{'pagedsearch'} = $dbh->prepare('select p2.name, p2.owner, p2.version, p2.submitted from ( select distinct name, owner from packages limit ?, 50) p1 left outer join ( select p3.* from ( select name,owner, version,submitted from packages order by id desc) p3 group by name, owner) p2 on p1.owner = p2.owner and p1.name = p2.name where upper(p1.owner) like ? or upper(p1.name) like ?'); 
    }
    $preps{'pagedsearch'}->execute($paged, '%' . uc($data->{'query'}) . '%', '%' . uc($data->{'query'}) . '%');
    my $returndata = [];
    while (my @row = $preps{'pagedsearch'}->fetchrow_array()) {
      push($returndata, {name => @row[0], owner => @row[1], version => @row[2], submitted => @row[3]});
    }
    $req->respond([200, 'dumbass', {'Content-Type' => 'application/json'}, j($returndata)]);
    return 1;
  },
  ('^' . $prefs->{'base'} . '/download$') => sub {
    reconnect;
    my $req = shift;
    my $data;
    try { $data = j($req->content); } catch { undef $data; }; 
    if (not defined $data) {
      $req->respond([200, 'dumbass', {'Content-Type' => 'application/json'}, j({failure => 1, reason => 'Send some POST data'})]);
      return 1;
    }
    if (not defined $data->{'name'}) {
      $req->respond([200, 'dumbass', {'Content-Type' => 'application/json'}, j({failure => 1, reason => '{name:<>} required but not found'})]);
      return 1;
    }
    my @args;
    my $sql = 'select repo,commit,version,owner,id,dependencies from packages where name = ?';
    $sql   .= ' and owner = ? '  if defined $data->{'author'};
    $sql   .= ' and version = ?' if defined $data->{'version'};
    $sql   .= ' order by id desc limit 0, 1';
    my $sth = $dbh->prepare($sql);
    push(@args, $data->{'name'});
    push(@args, $data->{'author'})  if defined $data->{'author'};
    push(@args, $data->{'version'}) if defined $data->{'version'};

    $sth->execute(@args);

    my @pkg = $sth->fetchrow_array;

    my $data = { };
    if (@pkg != 0) {
      $data = {repo => @pkg[0], commit => @pkg[1], version => @pkg[2], author => @pkg[3]};
      my $depends = [ ];
      print @pkg[5];
      try { $depends = j(@pkg[5]); } catch { $depends = [ ]; };
      $data->{'dependencies'} = $depends;
    }
    my $pkgid = @pkg[4];
   
    if (not defined $preps{'downloadpkg'}) {
      $preps{'downloadpkg'} = $dbh->prepare('insert into downloads (pkg, meta) values (?,?);');
    }
    try { $preps->execute($pkgid, $data->{'meta'}); } catch { };
    $req->respond([200, 'dumbass', {'Content-Type' => 'application/json'}, j($data)]);
    $sth->finish;
    return 1;
  },
});

$server->reg_cb(
  '' => sub{
    my ($httpd, $req) = @_;
    my $url = $req->url->as_string;
    $router->handle($url, $req);

    print "GET $url\n";
    $req->respond ({ content => ['text/html', $handlebars->render_string($cache{'main'}, { title => 'test' })] });
  }
);

$server->run;
