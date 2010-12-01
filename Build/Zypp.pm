package Build::Zypp;

use strict;

our $root = '';

sub parsecfg($)
{
  my $file = shift;
  my $repocfg = "$root/etc/zypp/repos.d/$file.repo";
  local *REPO;
  open(REPO, '<', $repocfg) or return undef;
  my $name;
  my $repo = {};
  while (<REPO>) {
    chomp;
    if (/^\[(.+)\]/) {
      $name = $1;
    } else {
      my ($key, $value) = split(/=/,$_,2);
      $repo->{$key} = $value if defined $key;
    }
  }
  close(REPO);
  return undef unless $name;
  $repo->{'description'} = $repo->{'name'} if exists $repo->{'name'};
  $repo->{'name'} = $name;
  return $repo;
}

1;

# vim: sw=2
