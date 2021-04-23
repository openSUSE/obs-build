################################################################
#
# Copyright (c) 2021 SUSE LLC
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

package PBuild::RepoMgr;

use strict;

use PBuild::Util;
use PBuild::RemoteRepo;
use PBuild::RemoteRegistry;
use PBuild::Verify;

#
# Create the repo manager
#
sub create {
  return bless {};
}

#
# Add a remote repository to the manager
#
sub addremoterepo {
  my ($repos, $bconf, $myarch, $builddir, $repourl, $buildtype, $opts) = @_;
  return addemptyrepo($repos) if $repourl =~ /^empty:/;
  my $id = Digest::MD5::md5_hex("$myarch/$repourl");
  return $repos->{$id} if $repos->{$id};
  my $repodir = "$builddir/.pbuild/_base/$id";
  my $bins = PBuild::RemoteRepo::fetchrepo($bconf, $myarch, $repodir, $repourl, $buildtype, $opts);
  $_->{'repoid'} = $id for @$bins;
  my $repo = { 'dir' => $repodir, 'bins' => $bins, 'url' => $repourl, 'arch' => $myarch, 'type' => 'repo', 'repoid' => $id };
  $repos->{$id} = $repo;
  return $repo;
}

#
# Add a remote registry to the manager
#
sub addremoteregistry {
  my ($repos, $bconf, $myarch, $builddir, $registry, $tags) = @_;
  my $repourl = $registry;
  $repourl = "https://$repourl" unless $repourl =~ /^[^\/]+\/\//;
  my $id = Digest::MD5::md5_hex("$myarch/$repourl");
  return $repos->{$id} if $repos->{$id};
  my $repodir = "$builddir/.pbuild/_base/$id";
  my $bins = PBuild::RemoteRegistry::fetchrepo($bconf, $myarch, $repodir, $repourl, $tags);
  $_->{'repoid'} = $id for @$bins;
  my $repo = { 'dir' => $repodir, 'bins' => $bins, 'url' => $repourl, 'arch' => $myarch, 'type' => 'registry', 'repoid' => $id };
  $repos->{$id} = $repo;
  return $repo;
}

#
# Add a local repository to the manager
#
sub addlocalrepo {
  my ($repos, $bconf, $myarch, $builddir, $pkgsrc, $pkgs) = @_;
  my $id = "$myarch/local";
  die("local repo already added\n") if $repos->{$id};
  my $bins = PBuild::LocalRepo::fetchrepo($bconf, $myarch, $builddir, $pkgsrc, $pkgs);
  $_->{'repoid'} = $id for @$bins;
  my $repo = { 'dir' => $builddir, 'bins' => $bins, 'arch' => $myarch, 'type' => 'local', 'repoid' => $id };
  $repos->{$id} = $repo;
  return $repo;
}

#
# Add an emptt repository to the manager
#
sub addemptyrepo {
  my ($repos) = @_;
  my $id = 'empty';
  return $repos->{$id} if $repos->{$id};
  my $repo = { 'bins' => [], 'type' => 'empty', 'repoid' => $id };
  $repos->{$id} = $repo;
  return $repo;
}

#
# Update the local reposiory with new binary data
#
sub updatelocalrepo {
  my ($repos, $bconf, $myarch, $builddir, $pkgsrc, $pkgs) = @_;
  my $id = "$myarch/local";
  my $repo = $repos->{$id};
  die("local repo does not exist\n") unless $repo;
  my $bins = PBuild::LocalRepo::fetchrepo($bconf, $myarch, $builddir, $pkgsrc, $pkgs);
  $_->{'repoid'} = $id for @$bins;
  $repo->{'bins'} = $bins;
}

#
# Fetch missing binaries from a remote repo/registry
#
sub getremotebinaries {
  my ($repos, $bins) = @_;
  my %tofetch;
  for my $q (@$bins) {
    push @{$tofetch{$q->{'repoid'}}}, $q unless $q->{'filename'};
  }
  for my $repoid (sort {$a cmp $b} keys %tofetch) {
    my $repo = $repos->{$repoid};
    die("bad repoid $repoid\n") unless $repo;
    if ($repo->{'type'} eq 'repo') {
      PBuild::RemoteRepo::fetchbinaries($repo, $tofetch{$repoid});
    } elsif ($repo->{'type'} eq 'registry') {
      PBuild::RemoteRegistry::fetchbinaries($repo, $tofetch{$repoid});
    } else {
      die("unknown repo type $repo->{'type'}\n");
    }
    $_->{'repoid'} = $repoid for @{$tofetch{$repoid}};
  }
}

#
# Setup the repo/containers directories used for image/container builds
#
sub copyimagebinaries {
  my ($repos, $bins, $dstdir) = @_;
  PBuild::Util::mkdir_p("$dstdir/repos/pbuild/pbuild");
  for my $q (@$bins) {
    my $repo = $repos->{$q->{'repoid'}};
    die("package $q->{'name'} has no repo\n") unless $repo;
    my $to;
    if ($q->{'name'} =~ /^container:/) {
      PBuild::Util::mkdir_p("$dstdir/containers");
      $to = "$q->{'name'}.tar";
      $to =~ s/^container://;
      $to =~ s/[\/:]/_/g;
      PBuild::Verify::verify_filename($to);
      $to = "$dstdir/containers/$to";
    } else {
      die("package $q->{'name'} is not available\n") unless $q->{'filename'};
      PBuild::Verify::verify_filename($q->{'filename'});
      $to = "$dstdir/repos/pbuild/pbuild/$q->{'filename'}";
    }
    if ($repo->{'type'} eq 'registry') {
      PBuild::RemoteRegistry::construct_containertar($repo->{'dir'}, $q, $to);
      next;
    }
    die("package $q->{'name'} is not available\n") unless $q->{'filename'};
    PBuild::Verify::verify_filename($q->{'filename'});
    my $from = "$repo->{'dir'}/$q->{'filename'}";
    $from = "$repo->{'dir'}/$q->{'packid'}/$q->{'filename'}" if $q->{'packid'};
    PBuild::Util::cp($from, $to);
  }
}

#
# Return the on-disk locations for a set of binary names
#
sub getbinarylocations {
  my ($repos, $bins) = @_;
  my %locations;
  for my $q (@$bins) {
    my $repo = $repos->{$q->{'repoid'}};
    die("package $q->{'name'} has no repo\n") unless $repo;
    die("package $q->{'name'} is not available\n") unless $q->{'filename'};
    if ($q->{'packid'}) {
      $locations{$q->{'name'}} = "$repo->{'dir'}/$q->{'packid'}/$q->{'filename'}";
    } else {
      $locations{$q->{'name'}} = "$repo->{'dir'}/$q->{'filename'}";
    }
  }
  return \%locations;
}

1;
