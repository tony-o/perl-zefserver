#!/usr/bin/env perl

use JSON::Tiny qw<encode_json decode_json>;
use File::Slurp qw<slurp>;
use File::Basename;
use Time::Piece;
use Modern::Perl;
use Try::Tiny;
use Data::Dumper;
use DBI;
use Cwd qw<abs_path cwd>;

my $abs = dirname(abs_path($0));
my $cfg = eval slurp "$abs/../../zef.conf";
my $dbh = DBI->connect("dbi:Pg:dbname=" . $cfg->{db}->{db_name}, $cfg->{db}->{username}, $cfg->{db}->{password});

my $ins = $dbh->prepare("INSERT INTO version (module, version, date, author, commit_id, meta) VALUES (?, ?, ?, ?, ?, ?)") or die $dbh->errstr;
my $insn = $dbh->prepare("INSERT INTO version (module, version, date, author, commit_id, meta) VALUES (?, ?, ?, ?, NULL, ?)") or die $dbh->errstr;
my $cnt = $dbh->prepare("SELECT count(*) c FROM version WHERE module = ? and  version = ? and  date = ? and  author = ? LIMIT 1") or die $dbh->errstr;
my $cntn = $dbh->prepare("SELECT count(*) c FROM version WHERE module = ? and  version = ? and  date = ? LIMIT 1") or die $dbh->errstr;

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

my ($dir, $metaf, $ocwd, $date, $commit, $meta, $auth, $ver, $name, @log, @combos);
$ocwd = cwd;
foreach my $mod (sort keys %$modules) {
  $dir = "$abs/modules/" . cfname($mod);
  next unless -e $dir;
  $metaf = -e "$dir/META.info" ? 'META.info' : -e "$dir/META6.json" ? 'META6.json' : -e "$dir/META.json" ? 'META.json' : -e "$dir/META6.info" ? 'META6.info' : '';
  say "couldn't find meta for $mod", next unless -e "$dir/$metaf";
  chdir $dir;
  $meta = slurp("$metaf");
  $meta = decode_json($meta);
  $auth = defined $meta->{auth} ?
            $meta->{auth} :
            undef;
  $name = $mod;
  @log = split "\n", `git log -Gversion -p '$metaf' | egrep '^(commit|Date|\\+\\s+"version)'`;
  foreach my $idx (0 .. @log - 1) {
    say "skipping on $mod", next unless
      defined $log[$idx] && defined $log[$idx + 2] &&
      substr($log[$idx], 0, 6) eq 'commit' && 
      substr($log[$idx + 1], 0, 5) eq 'Date:' &&
      substr($log[$idx + 2], 0, 1) eq '+';
    $ver = $log[$idx + 2];
    $ver =~ s/^.+?:\s*"//g;
    $ver =~ s/"\s*,?\s*$//g;
    $commit = $log[$idx];
    $commit =~ s/^commit\s*//g;
    $date = $log[$idx + 1];
    $date =~ s/^Date:\s*.+?\s//g;
    $date =~ s/\d+:\d+:\d+\s//g;
    $date =~ s/\s(\-|\+)\d+\s*$//g;
    $date = Time::Piece->strptime($date, '%b %d %Y');
    #in case META.info changed
    foreach my $mf (qw<META.info META6.json META.json META6.info>) {
      $meta = `git show $commit:$mf 2>&1`;
      last if $meta !~ m/^fatal/;
    }
    push @combos, {
      date => $date,
      author => $auth,
      commit => $commit,
      module => $mod,
      version => $ver,
      meta => $meta,
    };
  }
}

my $result;
foreach my $mod (@combos) {
  if (defined $mod->{author}) {
    $cnt->execute(
      $mod->{module}, $mod->{version}, $mod->{date}->strftime('%Y-%m-%d'), $mod->{author}
    );
    $result = $cnt->fetchrow_hashref();
    $ins->execute(
      $mod->{module}, $mod->{version}, $mod->{date}->strftime('%Y-%m-%d'), $mod->{author}, $mod->{commit}, $mod->{meta},
    ) if $result->{c} eq '0';
  } else {
    $cntn->execute(
      $mod->{module}, $mod->{version}, $mod->{date}->strftime('%Y-%m-%d')
    );
    $result = $cntn->fetchrow_hashref();
    $insn->execute(
      $mod->{module}, $mod->{version}, $mod->{date}->strftime('%Y-%m-%d'), $mod->{commit}, $mod->{meta},
    ) if $result->{c} eq '0';
  }

}
# (module, version, date, author, commit_id) VALUES (?, ?, ?, ?, ?)") or die $dbh->errstr;
