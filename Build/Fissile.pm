################################################################
#
# Copyright (c) 2017 SUSE Linux Products GmbH
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

package Build::Fissile;

use strict;

eval { require YAML::XS; $YAML::XS::LoadBlessed = 0; };
*YAML::XS::LoadFile = sub {die("YAML::XS is not available\n")} unless defined &YAML::XS::LoadFile;

sub parse {
  my ($cf, $fn) = @_;

  my $yml;
  eval { $yml = YAML::XS::LoadFile($fn); };
  return {'error' => "Failed to parse yml file"} unless $yml;

  my $ret = {};
  $ret->{'name'} = $yml->{'Name'} || 'fissile';
  $ret->{'version'} = $yml->{'Version'} if $yml->{'Version'};

  my @deps;
  for (@{$yml->{'DockerImageDeps'} || []}) {
    # This generates something like: "container:fissile-dev:201707081450"
    push @deps, "container:$_";
  }
  $ret->{'deps'} = \@deps;

  return $ret;
}

1;
