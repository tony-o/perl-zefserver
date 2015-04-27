#!/usr/bin/env perl

use JSON::Tiny qw<encode_json decode_json>;
use File::Slurp qw<slurp>;
use Modern::Perl;
use Try::Tiny;
use LWP::Simple;

my $url = 'http://git.io/vf5FV';

my @list = split("\n", get($url));
my $prov = slurp('provides.json');

try {
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
    say "Processed $data->{name}";
    1;
  } or next;
}
open my $fh, '>', 'provides.json';
print $fh encode_json($prov);
close $fh;

for my $src (keys $prov->{modules}) {
  my $path = $src;
  my $output = `git clone '$prov->{modules}->{$src}->{repo}' '$prov->{modules}->{$src}->{dir}'`;
  `cd '$prov->{modules}->{$src}->{dir}'; git pull`;
}
