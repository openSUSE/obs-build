################################################################
#
# Copyright (c) 2023 SUSE Linux Products GmbH
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

package Build::ProductCompose;

use strict;
use warnings;
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

sub filter_packages {
  my (@list) = @_;
  my @ret;
  for my $item (@list) {
  # FIXME filter by rules
    push @ret, $item;
  }
  return @ret;
}

sub parse {
  my ($cf, $fn) = @_;

  my $data = _load_yaml_file($fn);
  return { error => "Failed to parse file '$fn'" } unless defined $data;
  my $ret = {};
  $ret->{version} = $data->{'version'};
  $ret->{name} = $data->{'name'} or die "OBS Product name is missing";
  my $runtime_version = $data->{'runtime-version'};
  my $sdk = $data->{sdk};
  my @architectures;

  # Do we need source or debug packages?
  my $bo = $data->{'build_options'};
  if ($bo) {
    $ret->{'sourcemedium'} = 1 if $bo->{'source'};
    $ret->{'debugmedium'} = 1 if $bo->{'debug'};
    @architectures = @{$bo->{'architectures'} || []};
    if ($bo->{'flavors'}) {
      for my $flavor (@{$bo->{'flavors'}}) {
	my $f = $flavor->{$cf->{'buildflavor'}};
        next unless $f;
	@architectures = $f->{'architectures'};
      }
    }
    $ret->{'exclarch'} = \@architectures if @architectures;
  }

  my @unpack_packdeps = filter_packages(@{$data->{'unpack_packages'}});
  my @packdeps = filter_packages(@{$data->{'packages'}});
  my @merged;
  for my $dep (@unpack_packdeps, @packdeps) {
    if (ref($dep) eq 'HASH') {
      next if $dep->{'flavors'} && grep { $_ eq $cf->{'buildflavor'} } @{$dep->{'flavors'} || []};
      if ($dep->{'architectures'}) {
        my $match;
        for my $a (@architectures) {
	   $match = 1 if grep { $_ eq $a } @{$dep->{'architectures'} || []};
        }
	next unless $match;
      }
      for my $d (@{$dep->{'packages'}}) {
        push @merged, $d;
      }
    } else {
      push @merged, $dep;
    }
  }
  $ret->{deps} = \@merged;

  # We have currently no option to configure own path list for the product on purpose
  $ret->{path} = [ { project => '_obsrepositories', repository => '' } ];

  return $ret;
}

sub show {
    my ($fn, $field) = @ARGV;
    my $cf = {};
    my $d = parse($cf, $fn);
    die "$d->{error}\n" if $d->{error};
    my $value = $d->{ $field };
    if (ref $value eq 'ARRAY') {
        print "$_\n" for @$value;
    }
    else {
        print "$value\n";
    }
}

1;
