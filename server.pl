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

my $server = AnyEvent::HTTPD->new (port => 9001);
my $router = AnyEvent::HTTPD::REST::Router->new;
my $prefst = slurp 'prefs.json';
my $prefs  = j($prefst);
my $dbh    = DBI->connect($prefs->{'db'}->{'db'}, $prefs->{'db'}->{'user'}, $prefs->{'db'}->{'pass'}) || die 'couldn\'t connect to db';
my %preps;

$router->register({
  ('^' . $prefs->{'base'} . '/login$') => sub{ 
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
  }
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
