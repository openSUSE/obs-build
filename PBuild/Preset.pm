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
use PBuild::Util;

use strict;

my $dtd_pbuild = [
    'pbuild' =>
     [[ 'preset' =>
	    'name',
 	    'default',
	    'arch',
	  [ 'config' ],
	  [ 'repo' ],
	  [ 'registry' ],
	  [ 'assets' ],
	    'obs',
	  [ 'hostrepo' ],
     ]],
];

# read presets, take default if non given.
sub read_presets {
  my ($dir, $presetname) = @_;
  if (-f "$dir/_pbuild") {
    my $pbuild = PBuild::Structured::readxml("$dir/_pbuild", $dtd_pbuild);
    for my $preset (@{$pbuild->{'preset'} || []}) {
      next unless $preset->{'name'};
      if (defined($presetname)) {
	# check for selected preset
	return $preset if $presetname eq $preset->{'name'};
      } else {
	# check for default
	return $preset if exists $preset->{'default'};
      }
    }
  }
  die("unknown preset '$presetname'\n") if defined $presetname;
  return undef;
}

# get a list of defined presets
sub known_presets {
  my ($dir) = @_;
  my @presetnames;
  if (-f "$dir/_pbuild") {
    my $pbuild = PBuild::Structured::readxml("$dir/_pbuild", $dtd_pbuild);
    for my $d (@{$pbuild->{'preset'} || []}) {
      push @presetnames, $d->{'name'} if defined $d->{'name'};
    }
    @presetnames = PBuild::Util::unify(@presetnames);
  }
  return @presetnames;
}

# show resets
sub list_presets {
  my ($dir) = @_;
  my @presetnames = known_presets($dir);
  if (@presetnames) {
    print "Known presets:\n";
    print "  - $_\n" for @presetnames;
  } else {
    print "No presets defined\n";
  }
}

# get reponame/dist/repo/registry options from preset
sub apply_preset {
  my ($opts, $preset) = @_;
  $opts->{'arch'} = $preset->{'arch'} if $preset->{'arch'} && !$opts->{'arch'};
  $opts->{'reponame'} = $preset->{'name'} if $preset->{'name'} && !$opts->{'reponame'};
  push @{$opts->{'dist'}}, @{$preset->{'config'}} if $preset->{'config'} && !$opts->{'dist'};
  push @{$opts->{'repo'}}, @{$preset->{'repo'}} if $preset->{'repo'} && !$opts->{'repo'};
  push @{$opts->{'registry'}}, @{$preset->{'registry'}} if $preset->{'registry'} && !$opts->{'registry'};
  push @{$opts->{'assets'}}, @{$preset->{'assets'}} if $preset->{'assets'} && !$opts->{'assets'};
  $opts->{'obs'} = $preset->{'obs'} if $preset->{'obs'} && !$opts->{'obs'};
  push @{$opts->{'hostrepo'}}, @{$preset->{'hostrepo'}} if $preset->{'hostrepo'} && !$opts->{'hostrepo'};
}

1;
