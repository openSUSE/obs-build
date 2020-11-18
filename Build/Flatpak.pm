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

package Build::Flatpak;

use strict;
use warnings;
use Build::Deb;
use Build::Rpm;
use Data::Dumper;
#use URI; # not installed in kvm?
#use JSON::PP; # not installed in kvm?

my $yamlxs = eval { require YAML::XS; $YAML::XS::LoadBlessed = 0; return 1 };
my $yamlpp = eval { require YAML::PP; return YAML::PP->new };

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

sub parse {
  my ($cf, $fn) = @_;

  my $data;
  if ($fn =~ m/\.ya?ml\z/) {
    $data = _load_yaml_file($fn);
    return { error => "Failed to parse YAML file '$fn'" } unless defined $data;
  } elsif ($fn =~ m/\.json\z/) {
    # We don't have JSON::PP, but YAML is a superset of JSON
    $data = _load_yaml_file($fn);
    return { error => "Failed to parse JSON file '$fn'" } unless defined $data;
#    open my $fh, '<:encoding(UTF-8)', $fn or die $!;
#    my $json = do { local $/; <$fh> };
#    close $fh;
#    $data = eval { decode_json($json) };
#    return { error => "Failed to parse JSON file" } unless defined $data;
  } elsif (ref($fn) eq 'SCALAR') {
    $data = _load_yaml($$fn);		# used in the unit test
    return { error => "Failed to parse '$fn'" } unless defined $data;
  } else {
    $data = _load_yaml_file($fn);
    return { error => "Failed to parse file '$fn'" } unless defined $data;
  }

  my $ret = {};
  $ret->{name} = $data->{'app-id'} or die "Flatpak file is missing 'app-id'";
  $ret->{version} = $data->{version} || "0";
  my $runtime = $data->{runtime};
  my $runtime_version = $data->{'runtime-version'};
  my $sdk = $data->{sdk};

  my @packdeps;
  push @packdeps, "$sdk-v$runtime_version";
  push @packdeps, "$runtime-v$runtime_version";
  $ret->{deps} = \@packdeps;

  my @sources;
  if (my $modules = $data->{modules}) {
    for my $module (@$modules) {
      if (my $sources = $module->{sources}) {
        for my $source (@$sources) {
          if ($source->{type} eq 'archive') {
            my $url = $source->{url};
            my $path = $url;
            $path =~ s{.*/}{};	# Get filename
            push @sources, $path;
          }
        }
      }
    }
  }
  $ret->{sources} = \@sources;

#  warn __PACKAGE__.':'.__LINE__.$".Data::Dumper->Dump([\$ret], ['ret']);
  return $ret;
}

sub show {
    my ($fn, $field) = @ARGV;
    my $cf = {};
    my $d = parse($cf, $fn);
    die "$d->{error}\n" if $d->{error};
    my $value = $d->{ $field };
    print "$value\n";
}

1;
