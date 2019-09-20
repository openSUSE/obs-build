################################################################
#
# Copyright (c) 1995-2014 SUSE Linux Products GmbH
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 or 3 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program (see the file COPYING); if not, write to the
# Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA
#
################################################################

package Build::Zypp;

use strict;

our $root = '';

sub parsecfg {
  my ($repocfg, $reponame, $allrepos) = @_;

  local *REPO;
  open(REPO, '<', "$root/etc/zypp/repos.d/$repocfg") or return undef;
  my $name;
  my $repo = {};
  while (<REPO>) {
    chomp;
    next if /^\s*#/;
    s/\s+$//;
    if (/^\[(.+)\]/) {
      if ($allrepos && defined($name)) {
	$repo->{'description'} = $repo->{'name'} if defined $repo->{'name'};
	$repo->{'name'} = $name;
	push @$allrepos, $repo;
	undef $name;
	$repo = {};
      }
      last if defined $name;
      $name = $1 if !defined($reponame) || $reponame eq $1;
    } elsif (defined($name)) {
      my ($key, $value) = split(/=/, $_, 2);
      $repo->{$key} = $value if defined $key;
    }
  }
  close(REPO);
  return undef unless defined $name;
  $repo->{'description'} = $repo->{'name'} if defined $repo->{'name'};
  $repo->{'name'} = $name;
  push @$allrepos, $repo if $allrepos;
  return $repo;
}

sub repofiles {
  local *D;
  return () unless opendir(D, "/etc/zypp/repos.d");
  my @r = grep {!/^\./ && /.repo$/} readdir(D);
  closedir D;
  return sort(@r);
}

sub parseallrepos {
  my @r;
  for my $r (repofiles()) {
    parsecfg($r, undef, \@r);
  }
  return @r;
}

sub parserepo($) {
  my ($reponame) = @_;
  # first try matching .repo file
  if (-e "$root/etc/zypp/repos.d/$reponame.repo") {
    my $repo = parsecfg("$reponame.repo", $reponame);
    return $repo if $repo;
  }
  # then try all repo files
  for my $r (repofiles()) {
    my $repo = parsecfg($r, $reponame);
    return $repo if $repo;
  }
  die("could not find repo '$reponame'\n");
}

1;

# vim: sw=2
