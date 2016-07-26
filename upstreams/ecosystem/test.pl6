use LWP::UserAgent;
use JSON::Tiny qw<decode_json>;
use Try::Tiny;


sub checktravis {
  my ($repo) = @_;
  my $ua = LWP::UserAgent->new();
  return -1 unless $repo;
  $ua->default_header('Accept' => 'application/vnd.travis-ci.2+json');
  my $str  = $ua->get("https://api.travis-ci.org/repos$repo/builds?branch=master");
  my $x;
  warn "https://api.travis-ci.org/repos$repo";
  warn $str->status_line;
  if ($str->is_success) {
    $str = $str->decoded_content;
    warn "$mod\t$str";
    my $f = 0;
    my @r = try { my $t = decode_json $str; @{$t->{builds}}; };
    $x = shift @r;
    use Data::Dumper;
    print Dumper $x;
    return 'unknown' unless defined $x && defined $x->{state};
    return $x->{state};
  }

  return 'unknown';
}

warn 'result: ' . checktravis('/bbkr/GeoIPerl6');

