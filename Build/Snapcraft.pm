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

package Build::Snapcraft;

use strict;
use Build::Deb;

eval { require YAML::XS; $YAML::XS::LoadBlessed = 0; };
*YAML::XS::LoadFile = sub {die("YAML::XS is not available\n")} unless defined &YAML::XS::LoadFile;

sub parse {
  my ($cf, $fn) = @_;

  my $yaml;
  eval {$yaml = YAML::XS::LoadFile($fn);};
  return {'error' => "Failed to parse yaml file"} unless $yaml;

  my $ret = {};
  $ret->{'name'} = $yaml->{'name'};
  $ret->{'version'} = $yaml->{'version'};
  $ret->{'epoch'} = $yaml->{'epoch'} if $yaml->{'epoch'};

  # how should we report the built apps?
  my @packdeps;
  for my $p (@{$yaml->{'stage-packages'} || []}) {
    push @packdeps, $p;
  }
  for my $p (@{$yaml->{'build-packages'} || []}) {
    push @packdeps, $p;
  }
  for my $p (@{$yaml->{'after'} || []}) {
    push @packdeps, "snapcraft-part:$p";
  }

  for my $key (sort keys(%{$yaml->{'parts'} || {}})) {
    my $part = $yaml->{'parts'}->{$key};
    push @packdeps, "snapcraft-plugin:$part->{plugin}" if defined $part->{plugin};
    for my $p (@{$part->{'stage-packages'} || []}) {
      push @packdeps, $p;
    }
    for my $p (@{$part->{'build-packages'} || []}) {
      push @packdeps, $p;
    }
    for my $p (@{$part->{'after'} || []}) {
      next if $yaml->{'parts'}->{$p};
      push @packdeps, "build-snapcraft-part-$p";
    }
  }

  my %exclarchs;
  for my $arch (@{$yaml->{architectures} || []}) {
    my @obsarchs = Build::Deb::obsarch($arch);
    push @obsarchs, $arch unless @obsarchs;
    $exclarchs{$_} = 1 for @obsarchs;
  }

  $ret->{'exclarch'} = [ sort keys %exclarchs ] if %exclarchs;
#  $ret->{'badarch'} = $badarch if defined $badarch;
  $ret->{'deps'} = \@packdeps;
#  $ret->{'prereqs'} = \@prereqs if @prereqs;
#  $ret->{'configdependent'} = 1 if $ifdeps;

  return $ret;
}

1;
