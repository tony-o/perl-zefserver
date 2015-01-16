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
  my $stmt = $self->app->db->prepare('select p2.*, to_char(p2.submitted, \'DD Mon YYYY\') submitted from (select MAX(submitted), name, owner from packages group by name, owner) p1 left join (select * from packages) p2 on p2.submitted = p1.max and p2.name = p1.name;');

  my @data;

  $stmt->execute;
  while (my $hash = $stmt->fetchrow_hashref) {
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
