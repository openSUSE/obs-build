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

package PBuild::RemoteAssets;

use POSIX;

use PBuild::Util;
use PBuild::Download;

use strict;

#
# rename a file unless the target already exists
#
sub rename_unless_present {
  my ($old, $new) = @_;
  die("link $old $new: $!\n") if !link($old, $new) && $! != POSIX::EEXIST;
  unlink($old);
}

#
# Arch linux remote asset handling
#
sub archlinux_parse {
  my ($p, $arch) = @_;
  $arch = 'i686' if $arch =~ /^i[345]86$/;
  my @assets;
  for my $asuf ('', "_$arch") {
    my $sources = $p->{"source$asuf"};
    next unless @{$sources || []};
    my @digests;
    for my $digesttype ('sha512', 'sha256', 'sha1', 'md5') {
      @digests = map {$_ eq 'SKIP' ? $_ : "$digesttype:$_"} @{$p->{"${_}sums$asuf"} || []};
      last if @digests;
    }
    # work around bug in source parser
    my @sources;
    for (@$sources) {
      push @sources, $_;
      splice(@sources, -1, 1, $1, "$1.sig") if /(.*)\{,\.sig\}$/;
    }
    for my $s (@sources) {
      my $digest = shift @digests;
      next unless $s =~ /^https?:\/\/.*\/([^\.\/][^\/]+)$/s;
      my $file = $1;
      next if $p->{'files'}->{$file};
      my $asset = { 'file' => $file, 'url' => $s, 'type' => 'url' };
      $asset->{'digest'} = $digest if $digest && $digest ne 'SKIP';
      push @assets, $asset;
    }
  }
  return @assets;
}

#
# Spec file remote asset handling
#
sub spec_parse {
  my ($p) = @_;
  my @assets;
  for my $s (@{$p->{'remoteassets'} || []}) {
    my $url = $s->{'url'};
    next unless $s->{'url'} =~ /(?:^|\/)([^\.\/][^\/]+)$/s;
    my $file = $1;
    next if $p->{'files'}->{$file};
    undef $url unless $url =~ /^https?:\/\/.*\/([^\.\/][^\/]+)$/s;
    my $digest = $s->{'digest'};
    next unless $digest || $url;
    my $asset = { 'file' => $file };
    $asset->{'digest'} = $digest if $digest;
    $asset->{'url'} = $url if $url;
    $asset->{'type'} = 'url' if $url;
    push @assets, $asset;
  }
  return @assets;
}

# Fedora FedPkg / lookaside cache support

#
# Parse a fedora "sources" asset reference file
#
sub fedpkg_parse {
  my ($p) = @_;
  return unless $p->{'files'}->{'sources'};
  my $fd;
  my @assets;
  open ($fd, '<', "$p->{'dir'}/sources") || die("$p->{'dir'}/sources: $!\n");
  while (<$fd>) {
    chomp;
    my $asset;
    if (/^(\S+) \((.*)\) = ([0-9a-fA-F]{32,})$/s) {
      $asset = { 'file' => $2, 'digest' => lc("$1:$3") };
    } elsif (/^([0-9a-fA-F]{32})  (.*)$/) {
      $asset = { 'file' => $2, 'digest' => lc("md5:$1") };
    } else {
      warn("unparsable line in 'sources' file: $_\n");
      next;
    }
    push @assets, $asset if $asset->{'file'} =~ /^[^\.\/][^\/]*$/s;
  }
  close $fd;
  return @assets;
}

#
# Get missing assets from a fedora lookaside cache server
#
sub fedpkg_fetch {
  my ($p, $assetdir, $assets, $url) = @_;
  die("need a parsed name to download fedpkg assets\n") unless $p->{'name'};
  my @assets = grep {$_->{'digest'}} @$assets;
  return unless @assets;
  my $nassets = @assets;
  print "fetching $nassets assets from $url\n";
  for my $asset (@assets) {
    my $assetid = $asset->{'assetid'};
    my $adir = "$assetdir/".substr($assetid, 0, 2);
    PBuild::Util::mkdir_p($adir);
    # $url/<name>/<file>/<hashtype>/<hash>/<file>
    my $path = $asset->{'digest'};
    $path =~ s/:/\//;
    $path = "$p->{'name'}/$asset->{'file'}/$path/$asset->{'file'}";
    $path = PBuild::Util::urlencode($path);
    my $fedpkg_url = $url;
    $fedpkg_url =~ s/\/?$/\/$path/;
    if (PBuild::Download::download($fedpkg_url, "$adir/.$assetid.$$", undef, 'retry' => 3, 'digest' => $asset->{'digest'}, 'missingok' => 1)) {
      rename_unless_present("$adir/.$assetid.$$", "$adir/$assetid");
    }
  }
}

#
# Get missing assets from the InterPlanetary File System
#
sub ipfs_fetch {
  my ($p, $assetdir, $assets) = @_;
  my @assets = grep {($_->{'type'} || '') eq 'ipfs'} @$assets;
  return unless @assets;
  my $nassets = @assets;
  print "fetching $nassets from the InterPlanetary File System\n";
  # for now assume /ipfs is mounted...
  die("/ipfs is not available\n") unless -d '/ipfs';
  for my $asset (@assets) {
    my $assetid = $asset->{'assetid'};
    die("need a CID to download IPFS assets\n") unless $asset->{'cid'};
    my $adir = "$assetdir/".substr($assetid, 0, 2);
    PBuild::Util::mkdir_p($adir);
    PBuild::Util::cp($asset->{'cid'}, "$adir/.$assetid.$$");
    rename_unless_present("$adir/.$assetid.$$", "$adir/$assetid");
  }
}

#
# generic resource fetcher
#
sub url_fetch {
  my ($p, $assetdir, $assets) = @_;
  my %tofetch_hosts;
  # classify by hosts
  my %tofetch_host;
  for my $asset (grep {($_->{'type'} || '') eq 'url'} @$assets) {
    my $url = $asset->{'url'};
    die("need a url to download an asset\n") unless $url;
    die("weird download url '$url' for asset\n") unless $url =~ /^(.*?\/\/.*?)\//;
    push @{$tofetch_host{$1}}, $asset;
  }
  for my $hosturl (sort keys %tofetch_host) {
    my $tofetch = $tofetch_host{$hosturl};
    my $ntofetch = @$tofetch;
    print "fetching $ntofetch assets from $hosturl\n";
    for my $asset (@$tofetch) {
      my $assetid = $asset->{'assetid'};
      my $adir = "$assetdir/".substr($assetid, 0, 2);
      PBuild::Util::mkdir_p($adir);
      if (PBuild::Download::download($asset->{'url'}, "$adir/.$assetid.$$", undef, 'retry' => 3, 'digest' => $asset->{'digest'}, 'missingok' => 1)) {
        rename_unless_present("$adir/.$assetid.$$", "$adir/$assetid");
      }
    }
  }
}

1;
