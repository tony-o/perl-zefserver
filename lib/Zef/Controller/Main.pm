package Zef::Controller::Main;
use Mojo::Base qw<Mojolicious::Controller>;
use Text::Markdown qw<markdown>;
use Digest::SHA qw{sha256_hex};
use File::Slurp qw<slurp>;
use HTTP::Request::Common;
use LWP::UserAgent;
use JSON::Tiny;
use Try::Tiny;

sub home {
  my $self = shift;

  $self->stash(
    container => {
      title  => 'Main Street',
      active => '/',
    },
  );
}

sub modules {
  my $self = shift;
  my $stmt = $self->app->db->prepare('select p2.*, to_char(p2.submitted, \'DD Mon YYYY\') submitted from (select MAX(submitted), name, owner from packages group by name, owner) p1 left join (select packages.*, users.id uid from packages left join users on packages.owner = \'ZEF:\' || users.username) p2 on p2.submitted = p1.max and p2.name = p1.name order by p2.submitted desc limit 20;');

  my @data;

  $stmt->execute;
  while (my $hash = $stmt->fetchrow_hashref) {
    updatereadme($self, $hash);
    $hash->{'readme'} = substr($hash->{'readme'}, index($hash->{'readme'},'<p>'), index($hash->{'readme'}, '</p>')+4-index($hash->{'readme'}, '<p>'));
    $hash->{'readme'} =~ s/<\/p>\s*$//;
    $hash->{'readme'} = substr($hash->{'readme'}, 0, 350) . '</p>';
    push @data, $hash;
  }
  
  $self->stash(
    container => {
      active => '/modules',
      data   => [@data],
    },
  );
}

sub module {
  my $self = shift;
  my $stmt = $self->app->db->prepare('select p2.*, to_char(p2.submitted, \'DD Mon YYYY\') submitted from (select MAX(submitted), name, owner from packages group by name, owner) p1 left join (select * from packages) p2 on p2.submitted = p1.max and p2.name = p1.name WHERE p2.name = ? and p2.owner = ?;');
  $stmt->execute($self->stash->{'module'}, $self->stash->{'author'});
  my $data = $stmt->fetchrow_hashref;
  if (defined $data) {
    updatereadme($self, $data);
  }
  $self->stash(
    container => {
      author => $self->stash->{'author'},
      module => $self->stash->{'module'},
      data   => $data,
      active => '/modules',
      script => [
        '//cdnjs.cloudflare.com/ajax/libs/highlight.js/8.4/highlight.min.js',
        '/js/markdown.js',
        '/js/modulepagination.js',
      ],
      style  => [
        '//cdnjs.cloudflare.com/ajax/libs/highlight.js/8.4/styles/github.min.css',
      ],
    },
  );
}

sub login {
  my $self = shift;
  my $error;
  if (defined $self->stash->{'user'} && defined $self->stash->{'pass'}) {
    my $user = $self->stash->{'user'};
    my $pass = sha256_hex($self->stash->{'pass'} . $self->config->{'salt'});
    my $stmt = $self->app->db->prepare('select * from users where user = ? and pass = ?');
    $stmt->execute($user, $pass);
    my $user = $stmt->fetchrow_hashref;
    if (($user->{'id'} // 0) > 0) {
      $self->redirect('/profile');
      return;
    }
    $error = 'User/pass not found.';
  }
  $self->stash(container => {
    active => '/login',
    reason => $error,
  });
}


#HELPERZ
sub updatereadme {
  my ($self, $hash) = @_;
  warn 'serving cached content' if  defined $hash->{'readme'} && $hash->{'readme'} ne '';
  return if defined $hash->{'readme'} && $hash->{'readme'} ne '';
  my $ua  = LWP::UserAgent->new;
  my $req = HTTP::Request->new(POST => 'https://api.github.com/markdown/raw');
  $req->header('Content-Type' => 'text/plain');
  $req->content("".slurp($self->config->{'module_dir'} . '/' . $hash->{'id'} . '/README.md'));
  my $res = $ua->request($req); 
  if ($res->is_success) {
    $hash->{'readme'} = $res->content;
    my $stmt = $self->app->db->prepare('update packages set readme = ? where id = ?');
    $stmt->execute($hash->{'readme'}, $hash->{'id'});
    warn $res->content;
  }
}

{ smoke => 'everyday' };
