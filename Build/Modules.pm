################################################################
#
# Copyright (c) 2019 SUSE Linux Products GmbH
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

package Build::Modules;

use strict;
use Data::Dumper;

use YAML::XS;

$YAML::XS::LoadBlessed = 0;

#
# return a hash that maps NEVRA to modules
#
sub parse {
  my ($in, $res, %options) = @_;

  $res ||= {};
  # YAML::XS only alows a GLOB, so we need to do this old fashioned
  local *FD;
  my $fd;
  if (ref($in)) {
    *FD = $in;
  } else {
    if ($in =~ /\.gz$/) {
      open(FD, '-|', "gzip", "-dc", $in) || die("$in: $!\n");
    } else {
      open(FD, '<', $in) || die("$in: $!\n");
    }   
  }
  my %mods;
  my @mod = YAML::XS::LoadFile(\*FD);
  for my $mod (@mod) {
    next unless $mod->{'document'} eq 'modulemd';
    my $data = $mod->{'data'};
    next unless $data && ref($data) eq 'HASH';
    my $name = $data->{'name'};
    my $stream = $data->{'stream'};
    my $context = $data->{'context'};
    my $module = "$name-$stream";
    my @reqs;
    my $dependencies = $data->{'dependencies'};
    $dependencies = $dependencies->[0] if ref($dependencies) eq 'ARRAY';
    if ($dependencies && ref($dependencies) eq 'HASH') {
      my $requires = $dependencies->{'requires'};
      if ($requires && ref($requires) eq 'HASH') {
	for my $r (sort keys %$requires) {
	  my $rs = $requires->{$r};
	  $rs = $rs->[0] unless ref($rs) eq 'ARRAY';
	  if (@$rs) {
	    push @reqs, "$r-$rs->[0]";	# XXX: what about the rest?
	  } else {
	    push @reqs, $r;		# unversioned
	  }
	}
      }
    }
    my $moduleinfo = { 'name' => $module, 'stream' => $data->{'stream'} };
    $moduleinfo->{'context'} = $context if $context;
    $moduleinfo->{'requires'} = \@reqs if @reqs;
    $mods{"$module\@$context"} = $moduleinfo;
    next unless $data->{'artifacts'};
    my $rpms = $data->{'artifacts'}->{'rpms'};
    next unless $rpms && ref($rpms) eq 'ARRAY';
    for my $rpm (@$rpms) {
      my $nrpm = $rpm;
      $nrpm =~ s/-0:([^-]*-[^-]*\.[^\.]*)$/-$1/;	# normalize the epoch
      push @{$res->{$nrpm}}, $module;
      push @{$res->{$nrpm}}, "$module\@$context" if $context;
    }
  }
  # unify
  for (values %$res) {
    $_ = [ sort keys %{ { map {$_ => 1} @$_ } } ] if @$_ > 1;
  }
  # add moduleinfo
  $res->{'/moduleinfo'} = [ map {$mods{$_}} sort keys %mods ];
  return $res;
}

1;
