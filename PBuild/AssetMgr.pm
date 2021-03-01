################################################################
#
# Copyright (c) 2021 SUSE LLC
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

package PBuild::AssetMgr;

use strict;

use Digest::MD5 ();

use PBuild::Util;
use PBuild::RemoteAssets;

sub create {
  my ($assetdir) = @_;
  return bless { 'asset_dir' => $assetdir };
}

sub find_assets {
  my ($assetmgr, $p) = @_;
  PBuild::RemoteAssets::fedpkg_parse($p) if $p->{'files'}->{'sources'};
}

sub getremoteassets {
  my ($assetmgr, $p) = @_;
  if ($p->{'asset_files'}) {
    PBuild::RemoteAssets::fedpkg_fetch($p, $assetmgr->{'asset_dir'});
  }
}

sub copy_assets {
  my ($assetmgr, $p, $srcdir) = @_;
  my $assetdir = $assetmgr->{'asset_dir'};
  my $asset_files = $p->{'asset_files'};
  for my $file (sort keys %{$asset_files || {}}) {
    my $asset = Digest::MD5::md5_hex("$asset_files->{$file}  $file");
    my $adir = "$assetdir/".substr($asset, 0, 2);
    PBuild::Util::cp("$adir/$asset", "$srcdir/$file");
  }
}

1;
