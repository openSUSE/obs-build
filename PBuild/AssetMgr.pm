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
use PBuild::Source;
use PBuild::RemoteAssets;

#
# Create the asset manager
#
sub create {
  my ($assetdir) = @_;
  return bless { 'asset_dir' => $assetdir, 'handlers' => [] };
}

#
# Add a new asset resource to the manager
#
sub add_assetshandler {
  my ($assetmgr, $assetsurl) = @_;
  my $type = '';
  $type = $1 if $assetsurl =~ s/^([a-zA-Z0-9_]+)\@//;
  if ($type eq 'fedpkg') {
    push @{$assetmgr->{'handlers'}}, { 'url' => $assetsurl, 'type' => $type , 'asset_dir' => $assetmgr->{'asset_dir'}};
  } else {
    die("unsupported assets url '$assetsurl'\n");
  }
}

#
# Calculate the asset id used to cache the asset on-disk
#
sub get_assetid {
  my ($file, $asset) = @_;
  my $digest = $asset->{'digest'};
  if ($digest) {
    return Digest::MD5::md5_hex("$digest  $file");
  } elsif ($asset->{'cid'}) {
    return Digest::MD5::md5_hex("$asset->{'cid'}  $file");
  } elsif ($asset->{'url'}) {
    return Digest::MD5::md5_hex("$asset->{'url'}  $file");
  } else {
    die("$file: asset must either have a digest, cid, or an url\n");
  }
}

#
# Add the asset information to the package's srcmd5
#
sub update_srcmd5 {
  my ($assetmgr, $p) = @_;
  my $asset_files = $p->{'asset_files'};
  return unless $asset_files;
  my $assetdir = $assetmgr->{'asset_dir'};
  my %files = %{$p->{'files'}};
  for my $file(sort keys %$asset_files) {
    my $asset = $asset_files->{$file};
    my $assetid = get_assetid($file, $asset);
    $asset->{'assetid'} = $assetid;
    # use digest if we have one
    my $digest = $asset->{'digest'};
    if (length($digest || '') >= 32) {
      $files{$file} = substr($digest, 0, 32);
    } elsif ($asset->{'cid'}) {
      $files{$file} = Digest::MD5::md5_hex("$asset->{'cid'}  $file");
    } else {
      # unpinned asset
      my $adir = "$assetdir/".substr($assetid, 0, 2);
      my $fd;
      if (open($fd, '<', "$adir/$assetid")) {
        # already have it, use md5sum
	my $ctx = Digest::MD5->new;
	$ctx->addfile($fd);
	close $fd;
 	$files{$file} = $ctx->hexdigest();
      } else {
	# don't have it yet, mark as download on demand
	$files{$file} = 'd0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0';
      }
    }
  }
  $p->{'srcmd5'} = PBuild::Source::calc_srcmd5(\%files);
}

#
# Generate asset information from the package source
#
sub find_assets {
  my ($assetmgr, $p) = @_;
  PBuild::RemoteAssets::fedpkg_parse($p) if $p->{'files'}->{'sources'};
  update_srcmd5($assetmgr, $p) if $p->{'asset_files'};
}

#
# Make sure that we have all remote assets in our on-disk cache
#
sub getremoteassets {
  my ($assetmgr, $p) = @_;
  my $asset_files = $p->{'asset_files'};
  return unless $asset_files;

  my $assetdir = $assetmgr->{'asset_dir'};
  my @missing_assets;
  for my $file (sort keys %{$asset_files || {}}) {
    my $asset = $asset_files->{$file};
    my $assetid = $asset->{'assetid'};
    my $adir = "$assetdir/".substr($assetid, 0, 2);
    push @missing_assets, $file unless -e "$adir/$assetdir";
  }

  if (@missing_assets) {
    for my $handler (@{$assetmgr->{'handlers'}}) {
      if ($handler->{'type'} eq 'fedpkg') {
	PBuild::RemoteAssets::fedpkg_fetch($p, $handler->{'url'}, $handler->{'asset_dir'});
      } else {
	die("unsupported assets type $handler->{'type'}\n");
      }
    }
    if (grep {($asset_files->{$_}->{'type'} || '') eq 'ipfs'} @missing_assets) {
      PBuild::RemoteAssets::ipfs_fetch($p, $assetmgr->{'asset_dir'});
    }
  }

  # check if we have all assets
  my @missing;
  my $update_srcmd5;
  for my $file (@missing_assets) {
    my $asset = $asset_files->{$file};
    my $assetid = $asset->{'assetid'};
    my $adir = "$assetdir/".substr($assetid, 0, 2);
    push @missing, $file unless -e "$adir/$assetid";
    $update_srcmd5 = 1 unless $asset->{'digest'};
  }
  update_srcmd5($assetmgr, $p) if $update_srcmd5;
  if (@missing) {
    print "missing assets: @missing\n";
    $p->{'error'} = "missing assets: @missing";
  }
}

#
# Copy the assets from our cache to the build root
#
sub copy_assets {
  my ($assetmgr, $p, $srcdir) = @_;
  my $assetdir = $assetmgr->{'asset_dir'};
  my $asset_files = $p->{'asset_files'};
  for my $file (sort keys %{$asset_files || {}}) {
    my $asset = $asset_files->{$file};
    my $assetid = $asset->{'assetid'};
    my $adir = "$assetdir/".substr($assetid, 0, 2);
    PBuild::Util::cp("$adir/$assetid", "$srcdir/$file");
  }
}

1;
