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

sub add_pkgset {
  my ($ps1, $ps2) = @_;
  my %r = map {$_ => 1} @$ps1;
  return [ @$ps1, grep {!$r{$_}} @$ps2 ];
}

sub sub_pkgset {
  my ($ps1, $ps2) = @_;
  my %r = map {$_ => 1} @$ps2;
  my @r;
  for (@$ps1) {
    next if $r{$_};
    push @r, $_ unless /^([^ <=>]+)/ && $r{$1};
  }
  return \@r;
}

sub intersect_pkgset {
  my ($ps1, $ps2) = @_;
  my %r;
  for (@$ps2) {
    $r{$1} = 1 if /^([^ <=>]+)/;
  }
  my @r;
  for (@$ps1) {
    push @r, $_ if /^([^ <=>]+)/ && $r{$1};
  }
  return \@r;
}

sub get_pkgset {
  my ($packagesets, $setname, $arch, $flavor) = @_;
  $flavor = '' unless defined $flavor;
  my @seenps;
  my $lasts;
  for my $s (@$packagesets) {
    push @seenps, $lasts if defined $lasts;
    $lasts = $s;
    next unless $setname eq ($s->{'name'} || 'main');
    next if $s->{'flavors'} && !grep {$_ eq $flavor} @{$s->{'flavors'}};
    next if $s->{'architectures'} && !grep {$_ eq $arch} @{$s->{'architectures'}};
    push @seenps, $s;
    my $pkgset = $s->{'packages'} || [];
    for my $n (@{$s->{'add'} || []}) {
      $pkgset = add_pkgset($pkgset, get_pkgset(\@seenps, $n, $arch, $flavor));
    }
    for my $n (@{$s->{'sub'} || []}) {
      $pkgset = sub_pkgset($pkgset, get_pkgset(\@seenps, $n, $arch, $flavor));
    }
    for my $n (@{$s->{'intersect'} || []}) {
      $pkgset = intersect_pkgset($pkgset, get_pkgset(\@seenps, $n, $arch, $flavor));
    }
    return $pkgset;
  }
  return [];
}

sub get_pkgset_compat {
  my ($pkgs, $arch, $flavor) = @_;
  my @r;
  for my $s (@{$pkgs || []}) {
    if (ref($s) eq 'HASH') {
      next if $s->{'flavors'} && !grep {$flavor && $_ eq $flavor} @{$s->{'flavors'}};
      next if $s->{'architectures'} && !grep {$_ eq $arch} @{$s->{'architectures'}};
      push @r, @{$s->{'packages'} || []};
    } else {
      push @r, $s;
    }
  }
  return \@r;
}

sub parse {
  my ($cf, $fn) = @_;

  my $data = _load_yaml_file($fn);
  return { error => "Failed to parse file '$fn'" } unless defined $data;
  my $ret = {};
  $ret->{'version'} = $data->{'version'};
  $ret->{'name'} = $data->{'name'} or die "OBS Product name is missing";

  # Do we need source or debug packages?
  $ret->{'sourcemedium'} = 1 unless ($data->{'source'} || '') eq 'drop';
  $ret->{'debugmedium'} = 1 unless ($data->{'debug'} || '') eq 'drop';
  my @architectures = @{$data->{'architectures'} || []};
  if ($data->{'flavors'}) {
    if ($cf->{'buildflavor'}) {
      my $f = $data->{'flavors'}->{$cf->{'buildflavor'}};
      return { error => "Flavor '$cf->{'buildflavor'}' not found" } unless defined $f;
      @architectures = @{$f->{'architectures'} || []} if $f->{'architectures'};
    }
  }
  $ret->{'error'} = 'excluded' unless @architectures;
  $ret->{'exclarch'} = \@architectures if @architectures;
  $ret->{'bcntsynctag'} = $data->{'bcntsynctag'} if $data->{'bcntsynctag'};
  $ret->{'milestone'} = $data->{'milestone'} if $data->{'milestone'};

  my $flavor = $data->{'flavors'} ? $cf->{'buildflavor'} : undef;

  my $pkgs = [];
  for my $arch (@architectures) {
    if ($data->{'packagesets'}) {
      $pkgs = add_pkgset($pkgs, get_pkgset($data->{'packagesets'}, 'main', $arch, $flavor));
      for my $setname (@{$data->{'unpack'} || [ 'unpack' ]}) {
        $pkgs = add_pkgset($pkgs, get_pkgset($data->{'packagesets'}, $setname, $arch, $flavor));
      }
    } else {
      $pkgs = add_pkgset($pkgs, get_pkgset_compat($data->{'packages'}, $arch, $flavor));
      $pkgs = add_pkgset($pkgs, get_pkgset_compat($data->{'unpack_packages'}, $arch, $flavor));
    }
  }
  $ret->{'deps'} = $pkgs;

  # We have currently no option to configure own path list for the product on purpose
  $ret->{'path'} = [ { project => '_obsrepositories', repository => '' } ];

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
