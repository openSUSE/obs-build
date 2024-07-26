################################################################
#
# Copyright (c) 2024 SUSE LLC
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

package Build::IntrospectRust;

use strict;

use Build::ELF;
use Compress::Zlib ();

eval { require JSON::XS };
*JSON::XS::decode_json = sub {die("JSON::XS is not available\n")} unless defined &JSON::XS::decode_json;

sub rawversioninfo {
  my ($fh) = @_;
  my $elf = Build::ELF::readelf($fh);
  my ($off, $len);
  my $sect = $elf->findsect('.dep-v0') || $elf->findsect('rust-deps-v0');
  return undef unless $sect;
  my $comp_data = $elf->readsect($sect);
  my $data = Compress::Zlib::uncompress($comp_data);
  return $data;
}

sub versioninfo {
  my ($fh) = @_;
  my $data = rawversioninfo($fh);
  return undef unless $data;
  return JSON::XS::decode_json($data);
}

1;
