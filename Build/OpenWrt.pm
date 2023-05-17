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

package Build::OpenWrt;

use strict;
use warnings;
use Build::Deb;
use Build::Rpm;

my $yamlxs = eval { require YAML::XS; $YAML::XS::LoadBlessed = 0; return 1 };
my $yamlpp = eval { require YAML::PP; return YAML::PP->new };

sub _have_yaml_parser {
  return $yamlpp || $yamlxs ? 1 : undef;
}

sub _load_yaml {
  my ($yaml) = @_;
  my $data;
  if ($yamlpp) {
    $data = eval { $yamlpp->load_string($yaml) };
    return $data;
  }
  if ($yamlxs) {
    eval { $data = YAML::XS::Load($yaml) };
    return $data;
  }
  die "Neither YAML::PP nor YAML::XS available\n";
}

sub _load_yaml_file {
  my ($fn) = @_;
  my $data;
  if ($yamlpp) {
    $data = eval { $yamlpp->load_file($fn) };
    return $data;
  }
  if ($yamlxs) {
    eval { $data = YAML::XS::LoadFile($fn) };
    return $data;
  }
  die "Neither YAML::PP nor YAML::XS available\n";
}

sub _read_manifest {
  my ($fn) = @_;
  my $data;
  if ($fn =~ m/\.ya?ml\z/) {
    $data = _load_yaml_file($fn);
    return { error => "Failed to parse YAML file '$fn'" } unless defined $data;
  } elsif ($fn =~ m/\.json\z/) {
    # We don't have JSON::PP, but YAML is a superset of JSON anyway
    $data = _load_yaml_file($fn);
    return { error => "Failed to parse JSON file '$fn'" } unless defined $data;
  } elsif (ref($fn) eq 'SCALAR') {
    $data = _load_yaml($$fn);		# used in the unit test
    return { error => "Failed to parse '$fn'" } unless defined $data;
  } else {
    $data = _load_yaml_file($fn);
    return { error => "Failed to parse file '$fn'" } unless defined $data;
  }
  return $data;
}

sub parse {
  my ($cf, $fn) = @_;

  my $version = '';
  my @lines;
  if (ref($fn) eq 'SCALAR') {
    @lines = split m/(?<=\n)/, $$fn;
  }
  else {
    open my $fh, '<', $fn or return { error => "Failed to open file '$fn'" };
    @lines = <$fh>;
    close $fh;
  }

  for my $line (@lines) {
    if ($line =~ m/^#!BuildVersion: (\S+)/) {
      my $string = $1;
      if ($string =~ m/^[0-9.]+$/) {
          $version = $string;
      }
      else {
        return { error => "Invalid BuildVersion" };
      }
    }
  }
  my $data = _read_manifest($fn);
  my $ret = {};
  $ret->{version} = $version if $version;
  $ret->{name} = $data->{'name'} or die "OpenWrt file is missing name key.";
  $ret->{giturl} = $data->{'giturl'} or die "OpenWrt file is missing giturl key.";
  $ret->{sdkurl} = $data->{'sdkurl'} or die "OpenWrt file is missing sdkurl key.";
  $ret->{arch} = $data->{'arch'} or die "OpenWrt file is missing arch key.";
  $ret->{subarch} = $data->{'subarch'} or die "OpenWrt file is missing subarch key.";
  $ret->{relver} = $data->{'relver'} or die "OpenWrt file is missing relver key.";
  my $runtime_version = "tbd";

  my @packdeps;
  push @packdeps, "firstpackdep";
  push @packdeps, "secondpackdep";
  $ret->{deps} = \@packdeps;

  my @sources;
  if (my $modules = $data->{modules}) {
    for my $module (@$modules) {
      if (my $sources = $module->{sources}) {
        for my $source (@$sources) {
          if ($source->{type} eq 'archive') {
            push @sources, $source->{url};
          }
        }
      }
    }
  }
  $ret->{sources} = \@sources;

  return $ret;
}

sub show {
    my ($fn, $field) = @ARGV;
    my $cf = {};
    my $d = parse($cf, $fn);
    die "$d->{error}\n" if $d->{error};
    my $value = $d->{ $field } or die $field;
    if (ref $value eq 'ARRAY') {
        print "$_\n" for @$value;
    }
    else {
        print "$value\n";
    }
}

# This replaces http urls with local file urls because during build
# flatpak-builder has no network
sub rewrite {
  my ($fn) = @ARGV;
  my $data = _read_manifest($fn);
  if (my $modules = $data->{modules}) {
    for my $module (@$modules) {
      if (my $sources = $module->{sources}) {
        for my $source (@$sources) {
          if ($source->{type} eq 'archive') {
            my $path = $source->{url};
            $path =~ s{.*/}{}; # Get filename
            $source->{url} = "file:///usr/src/packages/SOURCES/$path";
          }
        }
      }
    }
  }
  my $yaml = '';
  if ($yamlpp) {
    # YAML::PP would allow us to keep key order
    $yaml = $yamlpp->dump_string($data);
  }
  elsif ($yamlxs) {
    $yaml = YAML::XS::Dump($data);
  }
  print $yaml;
}

1;
