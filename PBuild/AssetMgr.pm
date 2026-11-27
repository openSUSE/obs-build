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
use PBuild::Cpio;

our $goproxy_default = 'https://proxy.golang.org';

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
    push @{$assetmgr->{'handlers'}}, { 'url' => $assetsurl, 'type' => $type };
  } elsif ($type eq 'goproxy') {
    push @{$assetmgr->{'handlers'}}, { 'url' => $assetsurl, 'type' => $type };
  } else {
    die("unsupported assets url '$assetsurl'\n");
  }
}

#
# Calculate the asset id used to cache the asset on-disk
#
sub get_assetid {
  my ($file, $asset) = @_;
  return $asset->{'assetid'} if $asset->{'assetid'};
  my $digest = $asset->{'digest'};
  if ($digest) {
    return Digest::MD5::md5_hex("$digest  $file");
  } elsif ($asset->{'url'}) {
    return Digest::MD5::md5_hex("$asset->{'url'}  $file");
  } else {
    die("$file: asset must either have a digest or an url\n");
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
  # not available yet, use "download on demand" placeholder
  return 'd0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0';
}

#
# Add the asset information to the package's srcmd5
#
sub update_srcmd5 {
  my ($assetmgr, $p) = @_;
  my $old_srcmd5 = $p->{'srcmd5'};
  return 0 unless $old_srcmd5;
  my $asset_files = $p->{'asset_files'};
  return 0 unless %{$asset_files || {}};
  my %files = %{$p->{'files'}};
  for my $file (sort keys %$asset_files) {
    my $asset = $asset_files->{$file};
    die unless $asset->{'assetid'};
    # use first part of digest if we have one
    if ($asset->{'digest'} && $asset->{'digest'} =~ /:([a-f0-9]{32})/) {
      $files{$file} = $1;
    } elsif ($asset->{'immutable'}) {
      $files{$file} = substr($asset->{'assetid'}, 0, 32);
    } else {
      $files{$file} = calc_mutable_id($assetmgr, $asset);
    }
  }
  $p->{'srcmd5'} = PBuild::Source::calc_srcmd5(\%files);
  return $p->{'srcmd5'} eq $old_srcmd5 ? 0 : 1;
}

#
# Merge assets into the asset_files hash
#
sub merge_assets {
  my ($assetmgr, $p, $assets) = @_;
  my $files = $p->{'files'};
  for my $asset (@{$assets || []}) {
    my $file = $asset->{'file'};
    if (!$assetmgr->{'keep_all_assets'}) {
      # ignore asset if present in source list
      my $finalfile = $asset->{'finalfile'};
      if ($asset->{'isdir'}) {
        next if $files->{"$file/"} || $files->{"$file.obscpio"};
        next if $finalfile && ($files->{$finalfile} || $files->{"$finalfile/"});
      } else {
        next if $files->{$file};
        next if $finalfile && $files->{$finalfile};
      }
    }
    $asset->{'assetid'} ||= get_assetid($file, $asset);
    $p->{'asset_files'}->{$file} = $asset;
  }
}

#
# Generate asset information from the package source
#
sub find_assets {
  my ($assetmgr, $p) = @_;
  my $bt = $p->{'buildtype'} || '';
  my @assets;
  push @assets, @{$p->{'source_assets'} || []};
  push @assets, PBuild::RemoteAssets::fedpkg_parse($p) if $p->{'files'}->{'sources'};
  push @assets, PBuild::RemoteAssets::golang_parse($p) if $p->{'files'}->{'go.sum'};
  push @assets, PBuild::RemoteAssets::recipe_parse($p) if $bt eq 'spec' || $bt eq 'kiwi' || $bt eq 'arch' || $bt eq 'apk' || $bt eq 'docker';
  merge_assets($assetmgr, $p, \@assets);
  update_srcmd5($assetmgr, $p) if $p->{'asset_files'};
}

#
# Does a package have assets that may change over time?
#
sub has_mutable_assets {
  my ($assetmgr, $p) = @_;
  for my $asset (values %{$p->{'asset_files'} || {}}) {
    return 1 unless $asset->{'digest'} || $asset->{'immutable'};
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
# return the name of the cache file for an asset
#
sub get_asset_cachefile {
  my ($assetmgr, $asset) = @_;
  my $assetdir = $assetmgr->{'asset_dir'};
  my $assetid = $asset->{'assetid'};
  die("get_asset_cachefile: asset does not have an assetid\n") unless $assetid;
  my $adir = "$assetdir/".substr($assetid, 0, 2);
  return "$adir/$assetid";
}

#
# fetch a single remote asset (only type url supported for now)
# returns the asset cachefile if the asset is available, otherwise undef
#
sub getremoteasset_single {
  my ($assetmgr, $asset, $nofetch) = @_;
  my $assetfile = get_asset_cachefile($assetmgr, $asset);
  return $assetfile if -e $assetfile;
  if (!$nofetch) {
    die("getremoteasset_single: unsupported asset type $asset->{'type'}\n") if $asset->{'type'} ne 'url';
    PBuild::RemoteAssets::fetch_url_asset($assetmgr->{'asset_dir'}, $asset);
    return $assetfile if -e $assetfile;
  }
  return undef;
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
    } elsif ($handler->{'type'} eq 'goproxy') {
      PBuild::RemoteAssets::golang_fetch($p, $assetdir, \@assets, $handler->{'url'});
    } else {
      die("unsupported assets type $handler->{'type'}\n");
    }
    @assets = prune_cached_assets($assetmgr, @assets);
  }
  if (grep {($_->{'type'} || '') eq 'ipfs'} @assets) {
    PBuild::RemoteAssets::ipfs_fetch($p, $assetdir, \@assets);
    @assets = prune_cached_assets($assetmgr, @assets);
  }
  if (grep {($_->{'type'} || '') eq 'golang'} @assets) {
    if (!grep {$_->{'type'} eq 'goproxy'} (@{$assetmgr->{'handlers'}})) {
      PBuild::RemoteAssets::golang_fetch($p, $assetdir, \@assets, $goproxy_default);
      @assets = prune_cached_assets($assetmgr, @assets);
    }
  }
  if (grep {($_->{'type'} || '') eq 'url'} @assets) {
    PBuild::RemoteAssets::url_fetch($p, $assetdir, \@assets);
    @assets = prune_cached_assets($assetmgr, @assets);
  }
  if (@assets) {
    if (($p->{'buildtype'} || '') eq 'arch') {
      print "ignoring missing assets for arch repo: @missing\n";
      for my $asset (@assets) {
        delete $p->{'asset_files'}->{$asset->{'file'}};
      }
    } else {
      print "missing assets: @missing\n";
      $p->{'error'} = "missing assets: @missing";
      return;
    }
  }
  update_srcmd5($assetmgr, $p) if has_mutable_assets($assetmgr, $p);
}

sub unpack_obscpio {
  my ($assetmgr, $obscpio, $srcdir, $file) = @_;
  PBuild::Cpio::cpio_extract($obscpio, sub {
    my $name = $_[0]->{'name'};
    !$_[1] && ($name eq $file || $name =~ /^\Q$file\E\//) ? "$srcdir/$name" : undef
  }, 'postpone_symlinks' => 1, 'set_mode' => 1, 'set_mtime' => 1);
}

sub create_archive_from_obscpio {
  my ($assetmgr, $obscpio, $archivefile, $dorename) = @_;

  my $name = $archivefile;
  $archivefile =~ s/.*\///;
  die("unsupported archive format $archivefile\n") unless $archivefile =~ /^([^\.\-].*)\.tar(?:(\.xz|\.gz|\.zstd))?$/;
  my $dirname = $1;
  my $compressor = $2 || '';
  my $tmpdir = "$assetmgr->{'asset_dir'}/.createarchive$$";
  PBuild::Util::mkdir_p($tmpdir);
  PBuild::Cpio::cpio_extract($obscpio, "$tmpdir/$_[0]->{'name'}", 'postpone_symlinks' => 1, 'set_mode' => 1, 'set_mtime' => 1);
  my @dirs = PBuild::Util::ls($tmpdir);
  if (!@dirs) {
    mkdir("$tmpdir/empty");
    push @dirs, 'empty';
  }
  if ($dorename) {
    die("asset contains multiple directories, cannot create single archive\n") unless @dirs == 1;
    if ($dirname ne $dirs[0]) {
      rename("$tmpdir/$dirs[0]", "$tmpdir/$dirname") || die("rename $tmpdir/$dirs[0] $tmpdir/$dirname: $!\n");
    }
    @dirs = ($dirname);
  } else {
    my %dirs = map {$_ => 1} @dirs;
    die("asset contains invalid directories\n") if $dirs{"$dirname.tar"} || $dirs{"$dirname.tar.filelist"} || $dirs{"$dirname.tar$compressor"};
  }
  # check if our tar supports the --sort command
  system("/bin/sh", "-c", 'tar --sort=name --version >/dev/null 2>&1');
  die("need tar with --sort support\n") if $?;
  system('tar', '-C', $tmpdir, '-cf', "$tmpdir/$dirname.tar", '--owner=root:0', '--group=root:0', '--exclude=.git', '--sort=name', '--pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime', '--', @dirs) && die("tar failed: $?\n");
  system('xz', '--threads=2', '--', "$tmpdir/$dirname.tar") if $compressor eq '.xz';
  system('gzip', '-n', '--rsyncable', '--', "$tmpdir/$dirname.tar") if $compressor eq '.gz';
  system('zstd', '--rsyncable', '-15', '--threads=0', '--', "$tmpdir/$dirname.tar") if $compressor eq '.zst';
  die("archive creation failed\n") unless -e "$tmpdir/$dirname.tar$compressor";
  rename("$tmpdir/$dirname.tar$compressor", $archivefile) || die("rename $tmpdir/$dirname.tar$compressor $archivefile: $!\n");
  PBuild::Util::rm_rf($tmpdir);
}

sub unpack_asset {
  my ($assetmgr, $asset, $srcdir, $file) = @_;
  my $assetid = $asset->{'assetid'};
  my $adir = "$assetmgr->{'asset_dir'}/".substr($assetid, 0, 2);
  for my $unpackfile (@{$asset->{'filelist'} || [ $file ]}) {
    PBuild::Util::rm_rf("$srcdir/$unpackfile");
    unpack_obscpio($assetmgr, "$adir/$assetid", $srcdir, $unpackfile);
  }
}

sub create_archive_from_asset {
  my ($assetmgr, $asset, $srcdir, $file) = @_;
  my $assetid = $asset->{'assetid'};
  my $adir = "$assetmgr->{'asset_dir'}/".substr($assetid, 0, 2);
  my $archivefile = $asset->{'finalfile'} || "$file.tar.gz";
  unlink("$srcdir/$archivefile");
  create_archive_from_obscpio($assetmgr, "$adir/$assetid", "$srcdir/$archivefile", $asset->{'finalfile'} ? 1 : 0);
}

sub copy_bundle_asset {
  my ($assetmgr, $bundle, $srcdir, $bundlefile, $dirmode) = @_;

  die("copy_bundle_asset: unknown dirmode $dirmode\n") if $dirmode && $dirmode != 1 && $dirmode != 2;
  my $assetdir = $assetmgr->{'asset_dir'};
  my $bundlecpio = "$assetdir/.bundle$$.obscpio";
  my $fd;
  open($fd, '>', $bundlecpio) || die("$bundlecpio: $!\n");
  for my $basset (@$bundle) {
    my ($file, $asset) = @$basset;
    my $assetid = $asset->{'assetid'};
    my $adir = "$assetdir/".substr($assetid, 0, 2);
    if ($asset->{'isdir'}) {
      die("packing of assets is not supported\n") if $asset->{'donotpack'} && -d "$adir/$assetid";
      PBuild::Cpio::cpio_write_cpio($fd, "$adir/$assetid", 'notrailer' => 1);
    } else {
      $file = $asset->{'unpackfile'} if $asset->{'unpackfile'};
      PBuild::Cpio::cpio_write_file($fd, $adir, $assetid, 'name' => $file, 'mtime' => 0, 'notrailer' => 1);
    }
  }
  PBuild::Cpio::cpio_write_dir($fd, $assetdir, '.', 'name' => 'build-webcache', 'mtime' => 0, 'notrailer' => 1) if $bundlefile eq 'build-webcache';
  PBuild::Cpio::cpio_write_trailer($fd);
  close($fd);
  if ($dirmode) {
    die("unpack not supported for asset bundles\n") if $dirmode == 1;
    if ($dirmode == 2) {
      unlink("$srcdir/$bundlefile.tar.gz");
      create_archive_from_obscpio($assetmgr, $bundlecpio, "$srcdir/$bundlefile.tar.gz", 0);
    }
  } else {
    unlink("$srcdir/$bundlefile.obscpio");
    PBuild::Util::cp($bundlecpio, "$srcdir/$bundlefile.obscpio");
  }
  unlink($bundlecpio);
}

#
# Copy the assets from our cache to the build root
# dirmode: 0=obscpio 1=unpack 2=archive
#
sub copy_assets {
  my ($assetmgr, $p, $srcdir, $dirmode, $dobundle) = @_;
  my $assetdir = $assetmgr->{'asset_dir'};
  my $asset_files = $p->{'asset_files'};
  die("copy_assets: unknown dirmode $dirmode\n") if $dirmode && $dirmode != 1 && $dirmode != 2;
  my %bundles;
  for my $file (sort keys %{$asset_files || {}}) {
    my $asset = $asset_files->{$file};
    my $assetid = $asset->{'assetid'};
    my $adir = "$assetdir/".substr($assetid, 0, 2);
    die("asset $assetid is missing\n") unless -e "$adir/$assetid";
    if ($dobundle && $asset->{'bundlefile'}) {
      push @{$bundles{$asset->{'bundlefile'}}}, [ $file, $asset ];
      next;
    }
    if ($dirmode && $dirmode == 1 && $asset->{'unpackfile'}) {
      $file = $asset->{'unpackfile'};
      PBuild::Util::mkdir_p("$srcdir/$1") if $file =~ /(.*)\//;
    }
    if ($asset->{'isdir'}) {
      if ($dirmode) {
        unpack_asset($assetmgr, $asset, $srcdir, $file) if $dirmode == 1;
        create_archive_from_asset($assetmgr, $asset, $srcdir, $file) if $dirmode == 2;
        next;
      }
      $file .= ".obscpio";
    }
    unlink("$srcdir/$file");
    PBuild::Util::cp("$adir/$assetid", "$srcdir/$file");
  }
  copy_bundle_asset($assetmgr, $bundles{$_}, $srcdir, $_, $dirmode) for sort keys %bundles;
  if (has_mutable_assets($assetmgr, $p) && update_srcmd5($assetmgr, $p)) {
    copy_assets($assetmgr, $p, $srcdir);	# had a race, copy again
  }
}

#
# Move the assets from our cache to the build root, destroying the cache
# dirmode: 0=obscpio 1=unpack 2=archive
#
sub move_assets {
  my ($assetmgr, $p, $srcdir, $dirmode) = @_;
  my $assetdir = $assetmgr->{'asset_dir'};
  my $asset_files = $p->{'asset_files'};
  die("move_assets: unknown dirmode $dirmode\n") if $dirmode && $dirmode != 1 && $dirmode != 2;
  for my $file (sort keys %{$asset_files || {}}) {
    my $asset = $asset_files->{$file};
    my $assetid = $asset->{'assetid'};
    my $adir = "$assetdir/".substr($assetid, 0, 2);
    die("asset $assetid is missing\n") unless -e "$adir/$assetid";
    if ($asset->{'isdir'}) {
      if ($asset->{'donotpack'} && -d "$adir/$assetid") {
	# asset created with donotpack option, just rename
	# (we could support dirmode==2 in the future)
	die("packing of assets is not supported\n") unless $dirmode && $dirmode == 1;
      } else {
        if ($dirmode) {
          unpack_asset($assetmgr, $asset, $srcdir, $file) if $dirmode == 1;
          create_archive_from_asset($assetmgr, $asset, $srcdir, $file) if $dirmode == 2;
          next;
        }
	$file .= ".obscpio";
      }
    }
    if ($dirmode && $dirmode == 1 && $asset->{'unpackfile'}) {
      $file = $asset->{'unpackfile'};
      mkdir_p("$srcdir/$1") if $file =~ /(.*)\//;
    }
    rename("$adir/$assetid", "$srcdir/$file") || die("rename $adir/$assetid $srcdir/$file: $!\n");
    unlink("$adir/$assetid.etag");
  }
  if (has_mutable_assets($assetmgr, $p) && update_srcmd5($assetmgr, $p)) {
    die("had a race in move_assets\n");
  }
}

#
# Make sure that the assets of a package will be re-fetched by either deleting
# them or moving them away
#
sub force_update {
  my ($assetmgr, $p) = @_;
  my $assetdir = $assetmgr->{'asset_dir'};
  for my $asset (values %{$p->{'asset_files'} || {}}) {
    PBuild::RemoteAssets::force_update($assetdir, $asset) unless $asset->{'digest'} || $asset->{'immutable'};
  }
}

sub force_update_single {
  my ($assetmgr, $asset) = @_;
  PBuild::RemoteAssets::force_update($assetmgr->{'asset_dir'}, $asset) unless $asset->{'digest'} || $asset->{'immutable'};
}

1;
