#!/usr/bin/env perl

use lib 'lib';
use v5;
use AnyEvent::HTTPD::REST::Router;
use Digest::SHA qw{sha256_hex};
use File::Slurp qw{slurp};
use JSON::Tiny qw{j};
use AnyEvent::HTTPD;
use Data::Dumper;
use Try::Tiny;
use DBI;

my $prefst = slurp 'prefs.json';
my $prefs  = j($prefst);
my $server = AnyEvent::HTTPD->new (
               port => $prefs->{'port'} || 9000,
               ssl  => { cert_file => 'ssl.pem' },
             );
my $router = AnyEvent::HTTPD::REST::Router->new;
my $dbh;
my %preps;

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
    if (not defined $data->{'key'} || not defined $data->{'meta'} || not defined $data->{'meta'}->{'repository'} || not defined $data->{'meta'}->{'name'}) {
      $req->respond([200, 'dumbass', {'Content-Type' => 'application/json'}, j({failure => 1, reason => 'Invalid request..need {key:<>, meta:{repository:<>,name:<>}}'})]);
      return 1;
    }
    if (not defined $preps{'getuseridwkey'}) {
      $preps{'getuseridwkey'} = $dbh->prepare('select id, username from users where uq = ?');
    }
    $preps{'getuseridwkey'}->execute($data->{'key'});
    my ($id, $user) = $preps{'getuseridwkey'}->fetchrow_array();
    if (not defined $id || $id eq '') {
      $req->respond([200, 'dumbass', {'Content-Type' => 'application/json'}, j({error => 'Couldn\'t find user with specified key'})]);
      return 1;
    }
    my $cmd    = 'git ls-remote \'' . ($data->{'meta'}->{'repository'} =~ s{'}{'"'"'}rg) . '\' |grep HEAD |awk \'{ print $1; }\'';
    my $commit = `$cmd`;
    chomp $commit;
    if (not defined $commit || ($commit ~~ qr{^[a-fA-F0-9]{40,64}$}) == 1) {
      $req->respond([200, 'dumbass', {'Content-Type' => 'application/json'}, j({error => 'Couldn\'t reach repository or received bad data'})]);
      return 1;
    }
   
    if (not defined $preps{'getmoduleversion'}) {
      $preps{'getmoduleversion'} = $dbh->prepare('select version from packages where name = ? and owner = ? order by submitted desc limit 0, 1');
    }
    $preps{'getmoduleversion'}->execute($data->{'meta'}->{'name'}, "ZEF:$user");

    my $cv = $preps{'getmoduleversion'}->fetchrow_array();
    my $version = '1.0.0';
    if (defined $cv && $cv ne '') {
      my @versplit = split(/\./, $cv, 4);
      $version  = ((defined $data->{'majorvs'} && $data->{'majorvs'}) ? @versplit[0] + 1 : @versplit[0]) . '.';
      $version .= ((defined $data->{'minorvs'} && $data->{'minorvs'}) ? @versplit[1] + 1 : @versplit[1]) . '.';
      $version .= ((defined $data->{'majorvs'} && $data->{'majorvs'}) || (defined $data->{'minorvs'} && $data->{'minorvs'}) ? '0' : @versplit[2] + 1);
    }

    my $depends = defined $data->{'meta'}->{'dependencies'} ? j($data->{'meta'}->{'dependencies'}) : '{}';
    if (not defined $preps{'addpackage'}) {
      $preps{'addpackage'} = $dbh->prepare('insert into packages (name, owner, dependencies, version, repo, commit) values (?, ?, ?, ?, ?, ?)');
    }
    $preps{'addpackage'}->execute($data->{'meta'}->{'name'}, "ZEF:$user", $depends, $version, $data->{'meta'}->{'repository'}, $commit);

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
    $req->respond ({ content => ['text/html', 'Just another perl server.'] });
  }
);

$server->run;
