package Build::Zypp;

use strict;

our $root = '';

sub parsecfg {
  my ($repocfg, $reponame) = @_;

  local *REPO;
  open(REPO, '<', "$root/etc/zypp/repos.d/$repocfg") or return undef;
  my $name;
  my $repo = {};
  while (<REPO>) {
    chomp;
    if (/^\[(.+)\]/) {
      $name = $1 if !defined($reponame) || $reponame eq $1;
    } elsif (defined($name)) {
      my ($key, $value) = split(/=/, $_, 2);
      $repo->{$key} = $value if defined $key;
    }
  }
  close(REPO);
  return undef unless defined $name;
  $repo->{'description'} = $repo->{'name'} if exists $repo->{'name'};
  $repo->{'name'} = $name;
  return $repo;
}

sub parserepo($) {
  my ($reponame) = @_;
  # first try matching .repo file
  if (-e "$root/etc/zypp/repos.d/$reponame.repo") {
    my $repo = parsecfg($reponame, $reponame);
    return $repo if $repo;
  }
  # then try all repo files
  my @r;
  if (opendir(D, "$root/etc/zypp/repos.d")) {
    @r = grep {!/^\./ && /.repo$/} readdir(D);
    closedir D;
  }
  for my $r (sort @r) {
    my $repo = parsecfg($r, $reponame);
    return $repo if $repo;
  }
  die("could not find repo '$reponame'\n");
}

1;

# vim: sw=2
