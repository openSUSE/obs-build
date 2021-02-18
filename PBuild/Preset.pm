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

package PBuild::Preset;

use PBuild::Structured;

use strict;

my $dtd_pbuild = [
    'pbuild' =>
     [[ 'preset' =>
	    'name',
	  [ 'config' ],
	  [ 'repo' ],
	  [ 'registry' ],
     ]],
];

# read presets
sub read_presets {
  my ($dir, $presetname) = @_;
  my $preset;
  if (-f "$dir/_pbuild") {
    my $pbuild = PBuild::Structured::readxml("$dir/_pbuild", $dtd_pbuild);
    for my $d (@{$pbuild->{'preset'} || []}) {
      if (!defined($presetname) || (defined($d->{'name'}) && $presetname eq $d->{'name'})) {
        $preset = $d;
        last;
      }
    }
    die("unknown preset '$presetname'\n") if defined($presetname) && !$preset;
  }
  return $preset;
}

# get reponame/dist/repo/registry options from preset
sub apply_preset {
  my ($opts, $preset) = @_;
  $opts->{'reponame'} = $preset->{'name'} if $preset->{'name'} && !$opts->{'reponame'};
  push @{$opts->{'dist'}}, @{$preset->{'config'}} if $preset->{'config'} && !$opts->{'dist'};
  push @{$opts->{'repo'}}, @{$preset->{'repo'}} if $preset->{'repo'} && !$opts->{'repo'};
  push @{$opts->{'registry'}}, @{$preset->{'registry'}} if $preset->{'registry'} && !$opts->{'registry'};
}

1;
