#!/usr/bin/env perl

use JSON::Tiny qw<encode_json decode_json>;
use File::Slurp qw<slurp>;
use File::Basename;
use Modern::Perl;
use Try::Tiny;
use LWP::Simple;
use Cwd qw<abs_path>;
use Modern::Perl;
use Data::Dumper;
use DBI;

my $abs = dirname(abs_path($0));
my $cfg = eval slurp "$abs/../../zef.conf";
my $dbh = DBI->connect("dbi:Pg:dbname=" . $cfg->{db}->{db_name}, $cfg->{db}->{username}, $cfg->{db}->{password});

my $upd = $dbh->prepare("UPDATE packages SET version = ?, owner = ?, repo = ?, dependencies = ? WHERE name = ?") or die $dbh->errstr;
my $ins = $dbh->prepare("INSERT INTO packages (name, version, owner, repo, dependencies) VALUES (?, ?, ?, ?, ?)") or die $dbh->errstr;
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

my $modules = $prov->{modules};
foreach my $mod (keys $modules) {
  next unless -e "$abs/modules/" . cfname($mod);
  $sel->execute($mod) or die $sel->errstr;
  my $hr = $sel->fetchrow_hashref();
  if ($hr->{c} == 0) {
    $ins->execute($mod, $modules->{$mod}->{version}, $modules->{$mod}->{author}, $modules->{$mod}->{repo}, $modules->{$mod}->{dependencies});
  } else {
    $rwr->execute($mod);
    $hr = $rwr->fetchrow_hashref();
    $upd->execute($modules->{$mod}->{version}, $modules->{$mod}->{author}, $modules->{$mod}->{repo}, $modules->{$mod}->{dependencies}, $mod)
      unless ($hr->{version}||'')      eq ($modules->{$mod}->{version}||'')
          && ($hr->{owner}||'not in meta')       eq ($modules->{$mod}->{author}||'')
          && ($hr->{repo}||'')         eq ($modules->{$mod}->{repo}||'')
          && ($hr->{dependencies}||'') eq ($modules->{$mod}->{dependencies}||'');
  }
}
