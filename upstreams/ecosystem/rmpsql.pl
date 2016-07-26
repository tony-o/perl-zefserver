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

my $upd   = $dbh->prepare("UPDATE packages SET unavailable = ? WHERE name = ?") or die $dbh->errstr;
my $upd_m = $dbh->prepare("UPDATE packages SET stars = ?, openissues = ?, forks = ?, unavailable = ? WHERE name = ?") or die $dbh->errstr;

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

sub getj {
  my ($slug) = @_;
  my $json = try {
    my $t = `curl -u 'tony-o:4468b8f0de73332dda2f4274e80e3aadbd724efb' https://api.github.com/repos$slug 2>/dev/null`;
    $t = decode_json $t;
    return $t;
  } catch {
    return undef;
  };
  return $json;
}

our $modules = $prov->{modules};

foreach my $mod (keys %$modules) {
  next unless -e "$abs/modules/" . cfname($mod);
   
  my $repo = $modules->{$mod}->{repo};
  $repo =~ s/^git:/https:/;
  $repo =~ s/\.git$//;
  my $xrep = substr $repo, index($repo, '/', 8);
  $xrep =~ s/\.git$//;
  $xrep = getj($xrep);
  my $code = `curl -I $repo 2>/dev/null | head -n 1 | awk '{ print \$2 }'`;
  
  $upd_m->execute($xrep->{stargazers_count}, $xrep->{open_issues_count}, $xrep->{forks_count}, $code == 200 ? 0 : 1, $mod) if defined $xrep;
  $upd->execute($code == 200 ? 0 : 1, $mod) if not defined $xrep;
}
