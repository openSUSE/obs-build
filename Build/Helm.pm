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
use Digest;

eval { require YAML::XS; $YAML::XS::LoadBlessed = 0; };
*YAML::XS::LoadFile = sub {die("YAML::XS is not available\n")} unless defined &YAML::XS::LoadFile;

sub verify_config {
  my ($d) = @_;
  die("bad config\n") unless ref($d) eq 'HASH';
  for my $k ('name', 'version') {
    die("missing element '$k'\n") unless defined $d->{$k};
    die("bad element '$k'\n") unless ref($d->{$k}) eq '';
    die("empty element '$k'\n") if $d->{$k} eq '';
    die("bad element '$k'\n\n") if $d->{$k} =~ /[\/\000-\037]/;
  }
  die("bad name\n") if $d->{'name'} =~ /^[-\.]/;
}

sub parse {
  my ($cf, $fn) = @_;
  my $d;
  my $fd;
  return {'error' => "$fn: $!"} unless open($fd, '<', $fn);
  my @tags;
  while (<$fd>) {
    chomp;
    next if /^\s*$/;
    last unless /^\s*#/;
    push @tags, split(' ', $1) if /^#!BuildTag:\s*(.*?)$/;
  }
  close($fd);
  eval {
    $d = YAML::XS::LoadFile($fn);
    verify_config($d);
  };
  if ($@) {
    my $err = $@;
    chomp $@;
    return {'error' => "Failed to parse yml file: $err"};
  }
  
  my $res = {};
  $res->{'name'} = $d->{'name'};
  $res->{'version'} = $d->{'version'};
  my $release = $cf->{'buildrelease'};
  for (@tags) {
    s/<NAME>/$d->{'name'}/g;
    s/<VERSION>/$d->{'version'}/g;
    s/<RELEASE>/$release/g;
  }
  $res->{'containertags'} = \@tags if @tags;
  return $res;
}

sub show {
  my ($release, $disturl, $chart);
  while (@ARGV) {
    if (@ARGV > 2 && $ARGV[0] eq '--release') {
      (undef, $release) = splice(@ARGV, 0, 2); 
    } elsif (@ARGV > 2 && $ARGV[0] eq '--disturl') {
      (undef, $disturl) = splice(@ARGV, 0, 2);
    } elsif (@ARGV > 2 && $ARGV[0] eq '--chart') {
      (undef, $chart) = splice(@ARGV, 0, 2); 
    } else {
      last;
    }   
  }
  my ($fn, $field) = @ARGV;
  my $d = {};
  $d->{'buildrelease'} = $release if defined $release;
  $d = parse({}, $fn) if $fn;
  die("$d->{'error'}\n") if $d->{'error'};

  if ($field eq 'helminfo') {
    my $config_yaml = '';
    my $fd;
    die("$fn: $!\n") unless open($fd, '<', $fn);
    1 while sysread($fd, $config_yaml, 8192, length($config_yaml));
    close($fd);
    my $config = YAML::XS::Load($config_yaml);
    verify_config($config);
    my $config_json = Build::SimpleJSON::unparse($config)."\n";
    my $helminfo = {};
    $helminfo->{'name'} = $d->{'name'};
    $helminfo->{'version'} = $d->{'version'};
    $helminfo->{'release'} = $release if $release;
    $helminfo->{'tags'} = $d->{'containertags'} if $d->{'containertags'};
    $helminfo->{'disturl'} = $disturl if $disturl;
    $helminfo->{'buildtime'} = time();
    if ($chart) {
      $helminfo->{'chart'} = $chart;
      $helminfo->{'chart'} =~ s/.*\///;
      my $ctx = Digest->new("SHA-256");
      my $cfd;
      die("$chart: $!\n") unless open($cfd, '<', $chart);
      my @s = stat($cfd);
      $ctx->addfile($cfd);
      close($cfd);
      $helminfo->{'chart_sha256'} = $ctx->hexdigest;
      $helminfo->{'chart_size'} = $s[7];
    }
    $helminfo->{'config_json'} = $config_json;
    $helminfo->{'config_yaml'} = $config_yaml;
    $helminfo->{'_order'} = [ qw{name version release tags disturl buildtime chart config_json config_yaml chart_sha256 chart_size} ];
    $helminfo->{'_type'} = {'buildtime' => 'number', 'chart_size' => 'number' };
    print Build::SimpleJSON::unparse($helminfo)."\n";
    exit(0);
  }
  $d->{'nameversion'} = "$d->{'name'}-$d->{'version'}";		# convenience
  my $x = $d->{$field};
  $x = [ $x ] unless ref $x;
  print "@$x\n";
}

1;
