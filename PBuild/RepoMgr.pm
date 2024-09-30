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
  my ($bins, $meta) = PBuild::RemoteRepo::fetchrepo($bconf, $myarch, $repodir, $repourl, $buildtype, $opts);
  $_->{'repoid'} = $id for @$bins;
  my $repo = { 'dir' => $repodir, 'bins' => $bins, 'meta' => $meta, 'url' => $repourl, 'arch' => $myarch, 'type' => 'repo', 'repoid' => $id };
  $repo->{'obs'} = $opts->{'obs'} if $repourl =~ /^obs:/;
  $repo->{'no-repo-refresh'} = $opts->{'no-repo-refresh'} if $opts->{'no-repo-refresh'};
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
  my ($bins, $meta) = PBuild::RemoteRegistry::fetchrepo($bconf, $myarch, $repodir, $repourl, $tags);
  $_->{'repoid'} = $id for @$bins;
  my $repo = { 'dir' => $repodir, 'bins' => $bins, 'meta' => $meta, 'url' => $repourl, 'arch' => $myarch, 'type' => 'registry', 'repoid' => $id };
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
# Add an empty repository to the manager
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
      PBuild::RemoteRepo::fetchbinaries($repo->{'meta'}, $tofetch{$repoid});
    } elsif ($repo->{'type'} eq 'registry') {
      PBuild::RemoteRegistry::fetchbinaries($repo->{'meta'}, $tofetch{$repoid});
    } else {
      die("unsupported repo type $repo->{'type'}\n");
    }
    $_->{'repoid'} = $repoid for @{$tofetch{$repoid}};
  }
}

#
# Fetch missing gbininfo product binaries from a remote repo/registry
#
sub getremoteproductbinaries {
  my ($repos, $bins) = @_;
  my %tofetch;
  for my $q (@$bins) {
    push @{$tofetch{$q->{'repoid'}}}, $q unless $q->{'filename'};
  }
  for my $repoid (sort {$a cmp $b} keys %tofetch) {
    my $repo = $repos->{$repoid};
    die("bad repoid $repoid\n") unless $repo;
    if ($repo->{'type'} eq 'repo') {
      PBuild::RemoteRepo::fetchproductbinaries($repo->{'gbininfo_meta'}, $tofetch{$repoid});
    } else {
      die("unsupported repo type $repo->{'type'}\n");
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
  my %provenance;
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
    } elsif ($q->{'name'} =~ /^mkosi:/) {
      $to = "$dstdir/$q->{'lnk'}";
    } else {
      die("package $q->{'name'} is not available\n") unless $q->{'filename'};
      PBuild::Verify::verify_filename($q->{'filename'});
      $to = "$dstdir/repos/pbuild/pbuild/$q->{'filename'}";
    }
    if ($repo->{'type'} eq 'registry') {
      PBuild::RemoteRegistry::construct_containertar($repo->{'meta'}, $q, $to);
      next;
    }
    my $filename = $q->{'filename'};
    die("package $q->{'name'} is not available\n") unless $filename;
    if (!$q->{'packid'} && $q->{'package'}) {
      PBuild::Verify::verify_filename($filename);
      my $from = "$repo->{'dir'}/_gbins/$filename";
      $filename =~ s/^\Q$q->{'package'}-\E// if $filename =~ /\.rpm$/ || $filename =~ /\.slsa_provenance\.json$/;
      $to = "$dstdir/repos/pbuild/pbuild/$filename";
      $provenance{"$1.slsa_provenance.json"} = "$dstdir/repos/pbuild/pbuild/$q->{'package'}-_slsa_provenance.json" if $to =~ /(.*)\.rpm$/;
      PBuild::Util::cp($from, $to);
      next;
    }
    PBuild::Verify::verify_filename($filename);
    my $from = "$repo->{'dir'}/$filename";
    $from = "$repo->{'dir'}/$q->{'packid'}/$filename" if $q->{'packid'};
    $from = "$repo->{'dir'}/$q->{'packid'}/$q->{'lnk'}" if $q->{'packid'} && $q->{'lnk'};	# obsbinlnk
    PBuild::Util::cp($from, $to);
  }
  # create provenance links
  for my $p (sort keys %provenance) {
    if (-e $provenance{$p} && ! -e "$p") {
      link($provenance{$p}, $p) || die("link $provenance{$p} $p: $!\n");
    }
  }
}

#
# Write the container annotation of the basecontainer into the containers directory
#
sub writecontainerannotation {
  my ($repos, $q, $dstdir) = @_;
  my $repo = $repos->{$q->{'repoid'}};
  die("package $q->{'name'} has no repo\n") unless $repo;
  if ($q->{'name'} =~ /^container:/ && $repo->{'type'} eq 'registry') {
    PBuild::Util::mkdir_p("$dstdir/containers");
    PBuild::RemoteRegistry::construct_containerannotation($repo->{'meta'}, $q, "$dstdir/containers/annotation");
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

#
# Return gbininfo data for a repository
#
sub get_gbininfo {
  my ($repos, $repo) = @_;
  return $repo->{'gbininfo'} if $repo->{'gbininfo'};
  my ($gbininfo, $meta);
  if ($repo->{'type'} eq 'local') {
    $gbininfo = PBuild::LocalRepo::fetch_gbininfo($repo->{'dir'});
  } elsif ($repo->{'type'} eq 'repo') {
    # hack: reconstruct the part of the options we need
    my $opts = { 'no-repo-refresh' => $repo->{'no-repo-refresh'}, 'obs' => $repo->{'obs'} };
    ($gbininfo, $meta) = PBuild::RemoteRepo::fetch_gbininfo($repo->{'arch'}, $repo->{'dir'}, $repo->{'url'}, $opts);
  } else {
    die("get_gbininfo: unsupported repo type '$repo->{'type'}'\n");
  }
  my $id = $repo->{'repoid'};
  for my $p (values %$gbininfo) {
    $_->{'repoid'} = $id for values %$p;
  }
  $repo->{'gbininfo'} = $gbininfo;
  $repo->{'gbininfo_meta'} = $meta;
  return $gbininfo;
}

1;
