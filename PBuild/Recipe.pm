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

package PBuild::Recipe;

use strict;
use Build;

use PBuild::Service;

$Build::Kiwi::urlmapper = 0;	# disable url -> prp mapping

#
# Select a recipe file from the source files
#
sub find_recipe {
  my ($p, $type) = @_;
  my %files = map {$_ => $_} keys %{$p->{'files'} || {}};
  return $files{'_preinstallimage'} if $type ne 'kiwi' && keys(%files) == 1 && $files{'_preinstallimage'};
  return $files{'simpleimage'} if $files{'simpleimage'};
  return $files{'snapcraft.yaml'} if $type eq 'snapcraft' && $files{'snapcraft.yaml'};
  return $files{'appimage.yml'} if $type eq 'appimage' && $files{'appimage.yml'};
  return $files{'Dockerfile'} if $files{'Dockerfile'};
  return $files{'fissile.yml'} if $type eq 'fissile' && $files{'fissile.yml'};
  return $files{'Chart.yaml'} if $type eq 'helm' && $files{'Chart.yaml'};
  return (grep {/flatpak\.(?:ya?ml|json)$/} sort keys %files)[0] if $type eq 'flatpak';
  return $files{'PKGBUILD'} ? $files{'PKGBUILD'} : undef if $type eq 'arch';
  my $pkg = $p->{'pkg'};
  $pkg = $p->{'flavor'} if $p->{'flavor'};
  return $files{"$pkg.$type"} if $files{"$pkg.$type"};
  # try again without last components
  return $files{"$1.$type"} if $pkg =~ /^(.*?)\./ && $files{"$1.$type"};
  my @files = grep {/\.$type$/} keys %files;
  @files = grep {/^\Q$pkg\E/i} @files if @files > 1;
  return $files{$files[0]} if @files == 1;
  if (@files > 1) {
    @files = sort @files;
    return $files{$files[0]};
  }
  if ($type ne 'kiwi') {
    @files = grep {/\.kiwi$/} keys %files;
    @files = grep {/^\Q$pkg\E/i} @files if @files > 1;
    return $files{$files[0]} if @files == 1;
    if (@files > 1) {
      @files = sort @files;
      return $files{$files[0]};
    }
  }
  return undef;
}

#
# Find and parse a recipe file
#
sub parse {
  my ($bconf, $p, $buildtype, $arch, $bconf_host, $arch_host) = @_;
  if ($p->{'pkg'} eq '_product') {
    $p->{'error'} = 'excluded';
    return;
  }
  my $recipe = find_recipe($p, $buildtype);
  if (!$recipe) {
    $p->{'error'} = "no recipe found for buildtype $buildtype";
    return;
  }
  $p->{'recipe'} = $recipe;
  my $bt = Build::recipe2buildtype($recipe);
  if (!$bt) {
    $p->{'error'} = "do not know how to build $recipe";
    return;
  }
  $p->{'buildtype'} = $bt;
  my $d;
  local $bconf->{'buildflavor'} = $p->{'flavor'};
  eval {
    $d = Build::parse_typed($bconf, "$p->{'dir'}/$recipe", $bt);
    die("can not parse $recipe\n") unless $d;
    if ($bconf_host && $d->{'nativebuild'}) {
      $p->{'native'} = 1;
      local $bconf_host->{'buildflavor'} = $p->{'flavor'};
      $d = Build::parse_typed($bconf_host, "$p->{'dir'}/$recipe", $bt);
      die("can not parse $recipe\n") unless $d;
      $arch = $arch_host;
    }
    die("can not parse name from $recipe\n") unless $d->{'name'};
  };
  if ($@) {
    $p->{'error'} = $@;
    $p->{'error'} =~ s/\n.*//s;;
    return;
  }
  my $version = defined($d->{'version'}) ? $d->{'version'} : 'unknown';
  $p->{'version'} = $version;
  $p->{'name'} = $d->{'name'};
  $p->{'dep'} = $d->{'deps'};
  $p->{'onlynative'} = $d->{'onlynative'} if $d->{'onlynative'};
  $p->{'alsonative'} = $d->{'alsonative'} if $d->{'alsonative'};
  if ($d->{'prereqs'}) {
    my %deps = map {$_ => 1} (@{$d->{'deps'} || []}, @{$d->{'subpacks'} || []});
    my @prereqs = grep {!$deps{$_} && !/^%/} @{$d->{'prereqs'}};
    $p->{'prereq'} = \@prereqs if @prereqs;
  }
  if ($p->{'files'}->{'_service'}) {
    push @{$p->{'buildtimeservice'}}, $_ for PBuild::Service::get_buildtimeservices($p);
  }
  my $imagetype = $bt eq 'kiwi' && $d->{'imagetype'} ? ($d->{'imagetype'}->[0] || '') : '';
  if ($bt eq 'kiwi' && $imagetype eq 'product') {
    $p->{'nodbgpkgs'} = 1 if defined($d->{'debugmedium'}) && $d->{'debugmedium'} <= 0;
    $p->{'nosrcpkgs'} = 1 if defined($d->{'sourcemedium'}) && $d->{'sourcemedium'} <= 0;
  }
  my $myarch = $bconf->{'target'} ? (split('-', $bconf->{'target'}))[0] : $arch;
  $p->{'error'} = 'excluded' if $d->{'exclarch'} && !grep {$_ eq $myarch} @{$d->{'exclarch'}};
  $p->{'error'} = 'excluded' if $d->{'badarch'} && grep {$_ eq $myarch} @{$d->{'badarch'}};
  $p->{'imagetype'} = $d->{'imagetype'} if $d->{'imagetype'};

  # copy over asset information
  if ($bt eq 'arch') {
    for (sort keys %$d) {
      $p->{$_} = $d->{$_} if /^(?:source|md5sums|sha\d+sums)(?:_|$)/;
    }
  }
  $p->{'remoteassets'} = $d->{'remoteassets'} if ($bt eq 'spec' || $bt eq 'kiwi') && $d->{'remoteassets'};
  # check if we can build this
  if ($bt eq 'kiwi' && $imagetype eq 'product') {
    $p->{'error'} = 'cannot build kiwi products yet';
    return;
  }
}

# split host deps from deps if cross building 
sub split_hostdeps {
  my ($p, $bconf) = @_;
  return if $p->{'buildtype'} eq 'kiwi' || $p->{'buildtype'} eq 'docker' || $p->{'buildtype'} eq 'fissile';
  return if $p->{'native'};
  return unless @{$p->{'dep'} || []};
  my %onlynative = map {$_ => 1} @{$bconf->{'onlynative'} || []};
  my %alsonative = map {$_ => 1} @{$bconf->{'alsonative'} || []};
  for (@{$p->{'onlynative'} || []}) {
    if (/^!(.*)/) {
      delete $onlynative{$1};
    } else {
      $onlynative{$_} = 1;
    }
  }
  for (@{$p->{'alsonative'} || []}) {
    if (/^!(.*)/) {
      delete $alsonative{$1};
    } else {
      $alsonative{$_} = 1;
    }
  }
  my @hdep;
  $p->{'dep_host'} = \@hdep;
  return unless %onlynative || %alsonative;
  @hdep = grep {$onlynative{$_} || $alsonative{$_}} @{$p->{'dep'}};
  $p->{'dep'} = [ grep {!$onlynative{$_}} @{$p->{'dep'}}] if @hdep && %onlynative;
}

1;
