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
# calculate an id that identifies an mutable asset
#
sub calc_mutable_id {
  my ($assetmgr, $asset) = @_;
  my $assetid = $asset->{'assetid'};
  my $adir = "$assetmgr->{'asset_dir'}/".substr($assetid, 0, 2);
  my $fd;
  if (open($fd, '<', "$adir/$assetid")) {
    # already have it, use md5sum to track content
    my $ctx = Digest::MD5->new;
    $ctx->addfile($fd);
    close $fd;
    return $ctx->hexdigest();
  }
  return 'd0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0';	# download on demand
}

#
# Add the asset information to the package's srcmd5
#
sub update_srcmd5 {
  my ($assetmgr, $p) = @_;
  my $asset_files = $p->{'asset_files'};
  return 0 unless $asset_files;
  my $old_srcmd5 = $p->{'srcmd5'};
  my %files = %{$p->{'files'}};
  for my $file (sort keys %$asset_files) {
    my $asset = $asset_files->{$file};
    # use digest if we have one
    my $digest = $asset->{'digest'};
    if (length($digest || '') >= 32) {
      $files{$file} = substr($digest, 0, 32);
    } elsif ($asset->{'cid'}) {
      $files{$file} = Digest::MD5::md5_hex("$asset->{'cid'}  $file");
    } else {
      $files{$file} = calc_mutable_id($assetmgr, $asset);
    }
  }
  $p->{'srcmd5'} = PBuild::Source::calc_srcmd5(\%files);
  return $p->{'srcmd5'} eq $old_srcmd5 ? 0 : 1;
}

#
# Generate asset information from the package source
#
sub find_assets {
  my ($assetmgr, $p, $arch) = @_;
  my $bt = $p->{'buildtype'} || '';
  my @assets;
  push @assets, PBuild::RemoteAssets::fedpkg_parse($p) if $p->{'files'}->{'sources'};
  push @assets, PBuild::RemoteAssets::archlinux_parse($p, $arch) if $bt eq 'arch';
  push @assets, PBuild::RemoteAssets::recipe_parse($p, $arch) if $bt eq 'spec' || $bt eq 'kiwi';
  for my $asset (@assets) {
    $asset->{'assetid'} = get_assetid($asset->{'file'}, $asset);
    $p->{'asset_files'}->{$asset->{'file'}} = $asset;
  }
  update_srcmd5($assetmgr, $p) if $p->{'asset_files'};
}

#
# Does a package have assets that may change over time?
#
sub has_mutable_assets {
  my ($assetmgr, $p) = @_;
  for my $asset (values %{$p->{'asset_files'} || {}}) {
    return 1 unless $asset->{'digest'} || $asset->{'cid'};
  }
  return 0;
}

#
# remove the assets that we have cached on-disk
#
sub prune_cached_assets {
  my ($assetmgr, @assets) = @_;
  my $assetdir = $assetmgr->{'asset_dir'};
  my @pruned;
  for my $asset (@assets) {
    my $assetid = $asset->{'assetid'};
    my $adir = "$assetdir/".substr($assetid, 0, 2);
    push @pruned, $asset unless -e "$adir/$assetid";
  }
  return @pruned;
}

#
# Make sure that we have all remote assets in our on-disk cache
#
sub getremoteassets {
  my ($assetmgr, $p) = @_;
  my $asset_files = $p->{'asset_files'};
  return unless $asset_files;

  my $assetdir = $assetmgr->{'asset_dir'};
  my %assetid_seen;
  my @assets;
  # unify over the assetid
  for my $asset (map {$asset_files->{$_}} sort keys %$asset_files) {
    push @assets, $asset unless $assetid_seen{$asset->{'assetid'}}++;
  }
  @assets = prune_cached_assets($assetmgr, @assets);
  for my $handler (@{$assetmgr->{'handlers'}}) {
    last unless @assets;
    if ($handler->{'type'} eq 'fedpkg') {
      PBuild::RemoteAssets::fedpkg_fetch($p, $assetdir, \@assets, $handler->{'url'});
    } else {
      die("unsupported assets type $handler->{'type'}\n");
    }
    @assets = prune_cached_assets($assetmgr, @assets);
  }
  if (grep {($_->{'type'} || '') eq 'ipfs'} @assets) {
    PBuild::RemoteAssets::ipfs_fetch($p, $assetdir, \@assets);
    @assets = prune_cached_assets($assetmgr, @assets);
  }
  if (grep {($_->{'type'} || '') eq 'url'} @assets) {
    PBuild::RemoteAssets::url_fetch($p, $assetdir, \@assets);
    @assets = prune_cached_assets($assetmgr, @assets);
  }
  if (@assets) {
    my @missing = sort(map {$_->{'file'}} @assets);
    print "missing assets: @missing\n";
    $p->{'error'} = "missing assets: @missing";
    return;
  }
  update_srcmd5($assetmgr, $p) if has_mutable_assets($assetmgr, $p);
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
    PBuild::Util::cp("$adir/$assetid", $asset->{'isdir'} ? "$srcdir/$file.obscpio" : "$srcdir/$file");
  }
  if (has_mutable_assets($assetmgr, $p) && update_srcmd5($assetmgr, $p)) {
    copy_assets($assetmgr, $p, $srcdir);	# had a race, copy again
  }
}

1;
