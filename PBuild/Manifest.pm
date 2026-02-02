################################################################
#
# Copyright (c) 2026 SUSE LLC
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

package PBuild::Manifest;

use PBuild::Util;
use PBuild::Source;

sub read_manifest {
  my ($dir) = @_;
  eval { require YAML::XS; $YAML::XS::LoadBlessed = 0; };
  die("Need YAML::XS to parse the _manifest file\n") unless defined &YAML::XS::LoadFile;
  my $manifest = eval { YAML::XS::LoadFile("$dir/_manifest") };
  die("Could not parse _manifest file: $@") if $@;
  die("Bad _manifest file\n") unless ref($manifest) eq 'HASH';
  return $manifest;
}

sub find_packages {
  my ($root_dir, $pkg_dirs) = @_;
  $seend_sd ||= {};
  my $manifest = read_manifest($root_dir);
  my @pkgs;
  my @skippkgs;
  if (ref($manifest->{'packages'}) eq 'ARRAY') {
    for my $pkg (@{$manifest->{'packages'}}) {
      next if !defined($pkg) || ref($pkg) || $pkg eq '' || $pkg eq '.' || $pkg eq '..' || $pkg =~ /^\//;
      my $pkgdir = "$root_dir/$pkg";
      push @skippkgs, $1 if $pkg =~ /^([^\/]+)\//;
      $pkg =~ s/.*\///;
      next if $pkg eq '' || $pkg =~ /^[\._]/;
      next if $pkg_dirs->{$pkg} || !-d $pkgdir;
      push @pkgs, $pkg;
      $pkg_dirs->{$pkg} = $pkgdir;
    }
  }
  if (ref($manifest->{'subdirectories'}) eq 'ARRAY') {
    for my $sd (@{$manifest->{'subdirectories'}}) {
      next if !defined($sd) || ref($sd) || $sd eq '' || $sd eq '.' || $sd eq '..' || $sd =~ /^\//;
      next unless -d "$root_dir/$sd";
      push @skippkgs, $1 if $sd =~ /^([^\/]+)/;
      if (-e "$root_dir/$sd/_manifest") {
        push @pkgs, find_packages("$root_dir/$sd", $pkg_dirs);
      } else {
        push @pkgs, PBuild::Source::find_packages("$root_dir/$sd", $pkg_dirs);
      }
    }
  }
  if (!exists($manifest->{'packages'})) {
    @skippkgs = grep {!$pkg_dirs->{$_}} PBuild::Util::unify(@skippkgs);
    $pkg_dirs->{$_} = 1 for @skippkgs;
    push @pkgs, PBuild::Source::find_packages($root_dir, $pkg_dirs);
    delete $pkg_dirs->{$_} for @skippkgs;
  }
  return @pkgs;
}

1;
