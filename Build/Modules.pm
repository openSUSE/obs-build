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

sub parse {
  my ($in, $res, %options) = @_;

  $res ||= {};
  my $fd;
  if (ref($in)) {
    $fd = $in;
  } else {
    if ($in =~ /\.gz$/) {
      open($fd, '-|', "gzip", "-dc", $in) || die("$in: $!\n");
    } else {
      open($fd, '<', $in) || die("$in: $!\n");
    }   
  }
  my @mod = YAML::XS::LoadFile($fd);
  for my $mod (@mod) {
    next unless $mod->{'document'} eq 'modulemd';
    my $data = $mod->{'data'};
    next unless $data && ref($data) eq 'HASH';
    my $name = $data->{'name'};
    my $stream = $data->{'stream'};
    my $module = "$name-$stream";
    next unless $data->{'artifacts'};
    my $rpms = $data->{'artifacts'}->{'rpms'};
    next unless $rpms && ref($rpms) eq 'ARRAY';
    for my $rpm (@$rpms) {
      my $nrpm = $rpm;
      $nrpm =~ s/-0:([^-]*-[^-]*\.[^\.]*)$/-$1/;
      push @{$res->{$nrpm}}, $module;
    }
  }
  # unify
  for (values %$res) {
    $_ = [ sort keys %{ { map {$_ => 1} @$_ } } ] if @$_ > 1;
  }
  return $res;
}

1;
