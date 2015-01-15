package Zef::Controller::Main;
use Mojo::Base qw<Mojolicious::Controller>;

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
  my $stmt = $self->config->{'db'}->prepare('select * from ( select distinct name, owner from packages limit ?, 10) p1 left outer join ( select p3.* from ( select name,owner, version,submitted from packages order by id desc) p3 group by name, owner) p2 on p1.owner = p2.owner and p1.name = p2.name');

  my @data;

  $stmt->execute;
  while (my $hash = $stmt->fetchrow_arrayref) {
    push @data, $hash;
  }
  
  $self->stash(
    container => {
      active => '/modules',
      data   => [@data],
    },
  );
}

{ smoke => 'everyday' };
