#!/usr/bin/env perl

use JSON::Tiny qw<encode_json decode_json>;
use File::Slurp qw<slurp>;
use File::Basename;
use Modern::Perl;
use Try::Tiny;
use LWP::Simple;
use Cwd qw<abs_path>;
use DBI;

my $abs = dirname(abs_path($0));
my $cfg = eval slurp "$abs/../../zef.conf";
my $dbh = DBI->connect("dbi:Pg:dbname=" . $cfg->{db}->{db_name}, $cfg->{db}->{username}, $cfg->{db}->{password});
my $upd = $dbh->prepare("UPDATE packages SET readme = '' WHERE name = ?") or die $dbh->errstr;
my $dts = $dbh->prepare("UPDATE packages SET action = ?, submitted = ?, logo = ? WHERE name = ?") or die $dbh->errstr;


my $url = 'http://git.io/vf5FV';

my @list = split("\n", get($url));
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

#update provides.json cache
foreach my $meta (@list) {
  try {
    my $data = decode_json(get($meta));
    $prov->{modules}->{$data->{name}} = {} 
      if !defined $prov->{modules}->{$data->{name}};
    $prov->{modules}->{$data->{name}}->{provides} = [keys $data->{provides}];
    $prov->{modules}->{$data->{name}}->{author} =
      $data->{auth} ||
      (ref $data->{authors} eq 'ARRAY' ? $data->{authors}->[0] : $data->{authors}) ||
      $data->{author} ||
      'not in meta'; 
    $prov->{modules}->{$data->{name}}->{repo} = $data->{'source-url'};
    $prov->{modules}->{$data->{name}}->{dir} = 'modules/' . cfname($data->{name});
    $prov->{modules}->{$data->{name}}->{version} = $data->{version};
    $prov->{modules}->{$data->{name}}->{depends} = encode_json $data->{depends};
    say "Processed $data->{name}";
    1;
  } or next;
}
open my $fh, '>', $abs . '/provides.json';
print $fh encode_json($prov);
close $fh;

for my $src (keys $prov->{modules}) {
  my $path = $src;
  my $output;
  $output = `git clone '$prov->{modules}->{$src}->{repo}' '$prov->{modules}->{$src}->{dir}'`
    unless -e $prov->{modules}->{$src}->{dir};
  my $cd = "cd '$prov->{modules}->{$src}->{dir}'; ";
  my $xyz = `$cd git pull`;
  if (not $xyz =~ /Already up\-to\-date\./) {
    try { 
      $upd->execute($src); 
    } catch {
      say $_; 
    }
  }
  my $lc = `$cd git log -1 --format=%cd *`;
  my $fc = `$cd git log --reverse --format=%cd * | head -n1`;
  my $md = `$cd md5sum logotype/logo_32x32.png 2>/dev/null`;
  $md = substr $md, 0, 32;
  $md =~ s/^\s+|\s+$//g;
  if ($md ne '') {
    `$cd cp logotype/logo_32x32.png ../../../../public/img/logos/$md.png`;
  }
  $dts->execute($lc, $fc, $md ne '' ? "$md.png" : '', $src);
}
