################################################################
#
# Copyright (c) 2020 SUSE LLC
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

package Build::Helm;

use strict;

use Build::SimpleJSON;

# we do not want to parse the yaml file from the tar here, so just return some
# dummy result
sub parse {
  my ($cf, $fn) = @_;
  my $fd;
  return {'error' => "$fn: $!"} unless open($fd, '<', $fn);
  my $ret = { 'name' => 'helmchart', 'deps' => []};
  while (<$fd>) {
    chomp;
    my @s = split(' ', $_);
    next unless @s;
    my $k = lc(shift(@s));
    $ret->{'chartfile'} = $s[0] if @s && $k eq 'chart:';
    push @{$ret->{'containertags'}}, @s if @s && $k eq 'tags:';
  }
  close $fd;
  if (defined($ret->{'chartfile'})) {
    return {'error' => "illegal chartfile"} unless $ret->{'chartfile'} ne '';
    return {'error' => "illegal chartfile"} if $ret->{'chartfile'} =~ /[\/\000-\037]/;
    return {'error' => "illegal chartfile"} if $ret->{'chartfile'} =~ /^\./;
  }
  return $ret;
}

sub show {
  my ($release, $disturl, $chartconfig);
  while (@ARGV) {
    if (@ARGV > 2 && $ARGV[0] eq '--release') {
      (undef, $release) = splice(@ARGV, 0, 2); 
    } elsif (@ARGV > 2 && $ARGV[0] eq '--disturl') {
      (undef, $disturl) = splice(@ARGV, 0, 2);
    } elsif (@ARGV > 2 && $ARGV[0] eq '--chartconfig') {
      (undef, $chartconfig) = splice(@ARGV, 0, 2); 
    } else {
      last;
    }   
  }
  my ($fn, $field) = @ARGV;
  require YAML::XS;
  $YAML::XS::LoadBlessed = 0;
  my $d = {};
  $d = parse({}, $fn) if $fn;
  die("$d->{'error'}\n") if $d->{'error'};
  my $d2 = {};
  if ($chartconfig) {
    $d2 = YAML::XS::LoadFile($chartconfig);
    die unless $d2;
    my $name = $d2->{'name'};
    my $version = $d2->{'version'};
    die("no name\n") unless defined $name;
    die("bad name '$name'\n") if $name eq '';
    die("bad name '$name'\n") if $name =~ /\//;
    die("bad name '$name'\n") if $name =~ /^[-\.]/;
    die("bad name '$name'\n") if $name =~ /[\/\000-\037]/;
    die("no version\n") unless defined $version;
    die("bad version '$version'\n") if $version eq '';
    die("bad version '$version'\n") if $version =~ /\//;
    die("bad version '$version'\n") if $version =~ /[\/\000-\037]/;
    if ($field eq 'helminfo') {
      my @tags = @{$d->{'containertags'} || []};
      for (@tags) {
	s/<NAME>/$name/g;
	s/<VERSION>/$version/g;
	s/<RELEASE>/$release/g;
      }
      $d2->{'_order'} = [ qw{apiVersion name version kubeVersion description type keywords home sources dependencies maintainers icon appVersion deprecated annotations} ];
      my $config_json = Build::SimpleJSON::unparse($d2)."\n";
      my $manifest = {};
      $manifest->{'name'} = $name;
      $manifest->{'version'} = $version;
      $manifest->{'release'} = $release if $release;
      $manifest->{'tags'} = \@tags if @tags;
      $manifest->{'disturl'} = $disturl if $disturl;
      $manifest->{'buildtime'} = time();
      $manifest->{'chart'} = "$name-$version.tgz";
      $manifest->{'config_json'} = $config_json;
      $manifest->{'_order'} = [ qw{name version release tags disturl buildtime chart config_json} ];
      $manifest->{'_type'} = {'buildtime' => 'number'};
      print Build::SimpleJSON::unparse($manifest)."\n";
      exit(0);
    }
    $d = $d2;
    $d->{'nameversion'} = "$name-$version";
  }
  my $x = $d->{$field};
  $x = [ $x ] unless ref $x;
  print "@$x\n";
}

1;
