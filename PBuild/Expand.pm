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

package PBuild::Expand;

use strict;
use Build;

#
# configure the expander with the available repos
#
sub configure_repos {
  my ($bconf, $repos) = @_;

  my %packs;
  my %packs_done;

  my $binarytype = $bconf->{'binarytype'} || '';
  my $verscmp = $binarytype eq 'deb' ? \&Build::Deb::verscmp : \&Build::Rpm::verscmp;
  
  # this is what perl-BSSolv does. It is different to the
  # code in expanddeps!
  for my $repo (@$repos) {
    my $bins = $repo->{'bins'} || [];
    for my $bin (@$bins) {
      my $n = $bin->{'name'};
      next if $packs_done{$n};
      my $obin = $packs{$n};
      if ($obin) {
        my $evr = $bin->{'version'};
        $evr = "$bin->{'epoch'}:$evr" if $bin->{'epoch'};
        $evr .= "-$bin->{'release'}" if defined $bin->{'release'};
        my $oevr = $obin->{'version'};
        $oevr = "$obin->{'epoch'}:$oevr" if $obin->{'epoch'};
        $oevr .= "-$obin->{'release'}" if defined $obin->{'release'};
        my $arch = $bin->{'arch'} || '';
        $arch = 'noarch' if !$arch || $arch eq 'all' || $arch eq 'any';
        my $oarch = $obin->{'arch'} || '';
        $oarch = 'noarch' if !$oarch || $oarch eq 'all' || $oarch eq 'any';
	if ($oevr ne $evr) {
          next if ($verscmp->($oevr, $evr) || $oevr cmp $evr) >= 0;
        } elsif ($arch ne $oarch) {
	  next if $oarch eq 'noarch' && $arch ne 'noarch';
	  next if ($oarch eq 'noarch' || $arch ne 'noarch') && $oarch cmp $arch >= 0;
	}
      }
      $packs{$n} = $bin;
    }
    %packs_done = %packs;
  }
  Build::forgetdeps($bconf);	# free mem first
  Build::readdeps($bconf, undef, \%packs);
  return \%packs;
}

#
# expand dependencies of a single package
#
sub expand_deps {
  my ($p, $bconf, $subpacks) = @_;
  my $buildtype = $p->{'buildtype'} || 'unknown';
  delete $p->{'dep_experror'};
  return unless $p->{'name'};
  my @deps = @{$p->{'dep'} || []};
  if ($buildtype eq 'kiwi' || $buildtype eq 'docker') {
    if ($p->{'error'}) {
      $p->{'dep_expanded'} = [];
      return;
    }
    my ($ok, @edeps) = Build::get_build($bconf, [], @deps, '--ignoreignore--');
    if (!$ok) {
      delete $p->{'dep_expanded'};
      $p->{'dep_experror'} = join(', ', @edeps);
    } else {
      $p->{'dep_expanded'} = \@edeps;
    }
    return;
  }
  if ($buildtype eq 'preinstallimage') {
    my ($ok, @edeps) = Build::get_build($bconf, [], @deps);
    if (!$ok) {
      delete $p->{'dep_expanded'};
      $p->{'dep_experror'} = join(', ', @edeps);
    } else {
      $p->{'dep_expanded'} = \@edeps;
    }
    return;
  }
  if ($buildtype eq 'aggregate' || $buildtype eq 'patchinfo') {
    $p->{'dep_expanded'} = \@deps;
    return;
  }
  if ($p->{'genbuildreqs'}) {
    push @deps, @{$p->{'genbuildreqs'}};
  }
  my ($ok, @edeps) = Build::get_deps($bconf, $subpacks->{$p->{'name'}}, @deps);
  if (!$ok) {
    delete $p->{'dep_expanded'};
    $p->{'dep_experror'} = join(', ', @edeps);
  } else {
    $p->{'dep_expanded'} = \@edeps;
  }
}

1;
