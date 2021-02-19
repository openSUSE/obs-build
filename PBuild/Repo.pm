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

package PBuild::Repo;

use strict;

use PBuild::Util;
use PBuild::RemoteRepo;
use PBuild::RemoteRegistry;
use PBuild::Verify;

#
# Fetch missing binaries from a remote repo/registry
#
sub getremotebinaries {
  my ($repos, $dep2pkg, $bins) = @_;
  my %tofetch;
  for my $bin (PBuild::Util::unify(@$bins)) {
    my $q = $dep2pkg->{$bin};
    die("unknown binary $bin?\n") unless $q;
    next if $q->{'filename'};
    my $repono = $q->{'repono'};
    die("binary $bin does not belong to a repo?\n") unless defined $repono;
    push @{$tofetch{$repono}}, $q;
  }
  for my $repono (sort {$a <=> $b} keys %tofetch) {
    my $repo = $repos->[$repono];
    die("bad repono\n") unless $repo;
    if ($repo->{'type'} eq 'repo') {
      PBuild::RemoteRepo::fetchbinaries($repo, $tofetch{$repono});
    } elsif ($repo->{'type'} eq 'registry') {
      PBuild::RemoteRegistry::fetchbinaries($repo, $tofetch{$repono});
    } else {
      die("unknown repo type\n");
    }
  }
}

#
# Setup the repo/containers directories used for image/container builds
#
sub copyimagebinaries {
  my ($repos, $dep2pkg, $bins, $dstdir) = @_;
  PBuild::Util::mkdir_p("$dstdir/repos/pbuild/pbuild");
  for my $bin (@$bins) {
    my $q = $dep2pkg->{$bin};
    my $repono = $q->{'repono'};
    my $repo = $repos->[$repono || 0];
    die("bad package $bin\n") unless defined($repono) && $repo;
    if ($repo->{'type'} eq 'registry') {
      my $containerfile = "$q->{'name'}.tar";
      $containerfile =~ s/^container://;
      $containerfile =~ s/[\/:]/_/g;
      PBuild::Verify::verify_filename($containerfile);
      PBuild::Util::mkdir_p("$dstdir/containers");
      PBuild::RemoteRegistry::construct_containertar($repo->{'dir'}, $q, "$dstdir/containers/$containerfile");
      next;
    }
    die("missing package $bin\n") unless $q && $q->{'filename'};
    PBuild::Verify::verify_filename($q->{'filename'});
    my $from = "$repo->{'dir'}/$q->{'filename'}";
    $from = "$repo->{'dir'}/$q->{'packid'}/$q->{'filename'}" if $q->{'packid'};
    PBuild::Util::cp($from, "$dstdir/repos/pbuild/pbuild/$q->{'filename'}");
  }
}

#
# Return the on-disk locations for a set of binary names
#
sub getbinarylocations {
  my ($repos, $dep2pkg, $bins) = @_;
  my %locations;
  for my $bin (@$bins) {
    my $q = $dep2pkg->{$bin};
    die("missing package $bin\n") unless $q;
    my $repono = $q->{'repono'};
    my $repo = $repos->[$repono || 0];
    die("bad package $bin\n") unless defined($repono) && $repo;
    die("package $bin is not available\n") unless $q->{'filename'};
    if ($q->{'packid'}) {
      $locations{$bin} = "$repo->{'dir'}/$q->{'packid'}/$q->{'filename'}";
    } else {
      $locations{$bin} = "$repo->{'dir'}/$q->{'filename'}";
    }
  }
  return \%locations;
}

1;
