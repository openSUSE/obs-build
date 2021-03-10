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

package PBuild::Distro;

use strict;

use Build;

sub guess_distro_from_rpm {
  my ($arch) = @_;
  my $distribution;
  my @requires;
  my $fd;
  open($fd, '-|', 'rpm', '-q', '--qf', 'Distribution = %{DISTRIBUTION}\n', '--requires', 'rpm') || die;
  while (<$fd>) {
    chomp;
    if (/^Distribution = (.*)$/ && !defined($distribution)) {
      $distribution = $1;
    } else {
      push @requires, $_;
    }
  }
  close($fd);
  my $dist = Build::dist_canon($distribution, $arch);
  # need some extra work for sles11 and sles15 :(
  if ($dist =~ /^sles11-/) {
    $dist =~ s/^sles11-/sles11sp2-/ if grep {/^liblzma/} @requires;
  }
  if ($dist =~ /^sles15-/) {
    $dist =~ s/^sles15-/sles15sp2-/ if grep {/^libgcrypt/} @requires;
  }
  return $dist;
}

sub guess_distro {
  my ($arch) = @_;
  my $dist;
  if (-x '/bin/rpm' || -x '/usr/bin/rpm') {
    $dist = guess_distro_from_rpm($arch);
  }
  die("could not determine local dist\n") unless $dist;
  return $dist;
}

1;
