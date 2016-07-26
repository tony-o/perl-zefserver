#!/usr/bin/env perl

use JSON::Tiny qw<encode_json decode_json>;
use File::Slurp qw<slurp>;
use File::Basename;
use Modern::Perl;
use Try::Tiny;
use LWP::UserAgent;
use Cwd qw<abs_path>;
use Modern::Perl;
use Data::Dumper;
use DBI;

my $abs = dirname(abs_path($0));
my $cfg = eval slurp "$abs/../../zef.conf";
my $dbh = DBI->connect("dbi:Pg:dbname=" . $cfg->{db}->{db_name}, $cfg->{db}->{username}, $cfg->{db}->{password});

my $upd = $dbh->prepare("UPDATE packages SET version = ?, owner = ?, repo = ?, dependencies = ?, buildstatus = ? WHERE name = ?") or die $dbh->errstr;
my $ins = $dbh->prepare("INSERT INTO packages (name, version, owner, repo, dependencies, buildstatus) VALUES (?, ?, ?, ?, ?, ?)") or die $dbh->errstr;
my $sel = $dbh->prepare("SELECT COUNT(*) c FROM packages WHERE name = ?") or die $dbh->errstr;
my $rwr = $dbh->prepare("SELECT * FROM packages WHERE name = ? LIMIT 1") or die $dbh->errstr;

my $prov;

try {
  $prov = slurp($abs . '/provides.json');
  $prov = decode_json($prov);
  die 'invalid' if !defined $prov->{modules};
} catch { 
  $prov = { modules =>  { } };
};


sub cfname {
  my ($m) = @_;
  $m =~ s/:/-/g;
  $m =~ s/[^A-Za-z0-9\-\.]//g;
  return $m;
}

our $modules = $prov->{modules};

sub checktravis {
  my ($repo) = @_;
  my $ua = LWP::UserAgent->new();
  return -1 unless $repo;
  $ua->default_header('Accept' => 'application/vnd.travis-ci.2+json');
  my $str  = $ua->get("https://api.travis-ci.org/repos$repo/builds?branch=master");
  my $x;
  if ($str->is_success) {
    $str  = $str->decoded_content;
    my @r = try { my $t = decode_json $str; @{$t->{builds}}; };
    $x = shift @r;
    return $x->{state} if defined $x && defined $x->{state};
  }
  
  return 'unknown';
}

sub deps {
  my ($root) = @_;
  our $modules;

  my $depend = try { decode_json $modules->{$root}->{depends}; };
  my $return = { };
  
  $depend = [keys(%$depend)] if ref($depend) eq 'HASH';
  return $return unless ref($depend) eq 'ARRAY';
  for my $mod (@$depend) {
    $return->{$mod} = 1;
    for my $sdep (keys %{deps($mod)}) {
      $return->{$sdep} = 1;
    }
  }
  return $return;
}

foreach my $mod (keys %$modules) {
  next unless -e "$abs/modules/" . cfname($mod);

  my $depends = encode_json(deps($mod)); 
  my $slug    = try { 
    substr $modules->{$mod}->{repo}, index($modules->{$mod}->{repo}, '/', 8), -4;
  } || undef;
  $sel->execute($mod) or die $sel->errstr;
  my $hr = $sel->fetchrow_hashref();
  my $stat = checktravis($slug);
  warn $mod, "\t", $stat;
  if ($hr->{c} == 0) {
    $ins->execute($mod, $modules->{$mod}->{version}, $modules->{$mod}->{author}, $modules->{$mod}->{repo}, $depends, checktravis($slug));
  } else {
    $rwr->execute($mod);
    $hr = $rwr->fetchrow_hashref();
    $upd->execute($modules->{$mod}->{version}, $modules->{$mod}->{author}, $modules->{$mod}->{repo}, "$depends", $stat, $mod)
      unless ($hr->{version}||'')      eq ($modules->{$mod}->{version}||'')
          && ($hr->{owner}||'not in meta')       eq ($modules->{$mod}->{author}||'')
          && ($hr->{repo}||'')         eq ($modules->{$mod}->{repo}||'')
          && ($hr->{dependencies}||'') eq ("$depends"||'')
          && ($hr->{buildstatus}||'')  eq ("$stat"||'');
  }
}
