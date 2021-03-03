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

# Arch linux remote assers
sub archlinux_parse {
  my ($p, $arch) = @_;
  $arch = 'i686' if $arch =~ /^i[345]86$/;
  for my $asuf ("_$arch", '') {
    my $sources = $p->{"source$asuf"};
    next unless @{$sources || []};
    my @digests;
    my $digesttype;
    for ('sha512', 'sha256', 'sha1', 'md5') {
      $digesttype = $_;
      @digests = @{$p->{"${_}sums$asuf"} || []};
      last if @digests;
    }
    # work around bug in source parser
    my @sources;
    for my $s (@$sources) {
      if ($s =~ s/\{,\.sig\}$//) {
	push @sources, $s, "$s.sig";
	next;
      }
      push @sources, $s;
    }
    for my $s (@sources) {
      my $digest = shift @digests;
      next unless $s =~ /^https?:\/\/.*\/([^\.\/][^\/]+)$/s;
      my $file = $1;
      next if $p->{'files'}->{$file};
      my $asset = { 'file' => $file, 'url' => $s, 'type' => 'url' };
      $asset->{'digest'} = "$digesttype:$digest" if $digest && $digest ne 'SKIP';
      $p->{'asset_files'}->{$file} = $asset;
    }
  }
}

# Fedora FedPkg / lookaside cache support

#
# Parse a fedora "sources" asset reference file
#
sub fedpkg_parse {
  my ($p) = @_;
  my $files = $p->{'files'};
  return unless $files->{'sources'};
  my $fd;
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
    $p->{'asset_files'}->{$asset->{'file'}} = $asset if $asset->{'file'} =~ /^[\.\/][^\/]*$/s;
  }
  close $fd;
}

#
# Get missing assets from a fedora lookaside cache server
#
sub fedpkg_fetch {
  my ($p, $url, $assetdir) = @_;
  my %tofetch;
  my $asset_files = $p->{'asset_files'};
  for my $file (sort keys %{$asset_files || {}}) {
    my $asset = $asset_files->{$file};
    next unless $asset->{'digest'};	# can only handle those
    my $assetid = $asset->{'assetid'};
    die("$file: no assetid element?\n") unless $assetid;
    my $adir = "$assetdir/".substr($assetid, 0, 2);
    next if -e "$adir/$assetid";
    $tofetch{$assetid} = [ $file, $asset ] ;
  }
  return unless %tofetch;
  die("need a parsed name to download fedpkg assets\n") unless $p->{'name'};
  my $ntofetch = keys %tofetch;
  print "fetching $ntofetch assets from $url\n";
  for my $assetid (sort keys %tofetch) {
    my $file = $tofetch{$assetid}->[0];
    my $digest = $tofetch{$assetid}->[1]->{'digest'};
    die("need a digest to download fedpkg assets\n") unless $digest;
    my $adir = "$assetdir/".substr($assetid, 0, 2);
    PBuild::Util::mkdir_p($adir);
    # $url/<name>/<file>/<hashtype>/<hash>/<file>
    my $fedpkg_url = $url;
    $fedpkg_url =~ s/\/?$/\//;
    my $chksum_path = $digest;
    $chksum_path =~ s/:/\//;
    $fedpkg_url .= "$p->{'name'}/$file/$chksum_path/$file";
    if (PBuild::Download::download($fedpkg_url, "$adir/.$assetid.$$", undef, 'retry' => 3, 'digest' => $digest, 'missingok' => 1)) {
      rename_unless_present("$adir/.$assetid.$$", "$adir/$assetid");
    }
  }
}

#
# Get missing assets from the InterPlanetary File System
#
sub ipfs_fetch {
  my ($p, $assetdir) = @_;
  my %tofetch;
  my $asset_files = $p->{'asset_files'};
  for my $file (sort keys %{$asset_files || {}}) {
    my $asset = $asset_files->{$file};
    next unless ($asset->{'type'} || '') eq 'ipfs';	# can only handle those
    my $assetid = $asset->{'assetid'};
    die("$file: no assetid element?\n") unless $assetid;
    my $adir = "$assetdir/".substr($assetid, 0, 2);
    next if -e "$adir/$assetid";
    $tofetch{$assetid} = [ $file, $asset ] ;
  }
  return unless %tofetch;
  my $ntofetch = keys %tofetch;
  print "fetching $ntofetch assets from the InterPlanetary File System\n";
  # for now assume /ipfs is mounted...
  die("/ipfs is not available\n") unless -d '/ipfs';
  for my $assetid (sort keys %tofetch) {
    my $file = $tofetch{$assetid}->[0];
    my $cid = $tofetch{$assetid}->[1]->{'cid'};
    die("need a CID to download IPFS assets\n") unless $cid;
    my $adir = "$assetdir/".substr($assetid, 0, 2);
    PBuild::Util::mkdir_p($adir);
    PBuild::Util::cp("$cid", "$adir/.$assetid.$$");
    rename_unless_present("$adir/.$assetid.$$", "$adir/$assetid");
  }
}

#
# generic resource fetcher
#
sub url_fetch {
  my ($p, $assetdir) = @_;
  my %tofetch;
  my $asset_files = $p->{'asset_files'};
  for my $file (sort keys %{$asset_files || {}}) {
    my $asset = $asset_files->{$file};
    next unless ($asset->{'type'} || '') eq 'url';	# can only handle those
    my $assetid = $asset->{'assetid'};
    die("$file: no assetid element?\n") unless $assetid;
    my $adir = "$assetdir/".substr($assetid, 0, 2);
    next if -e "$adir/$assetid";
    $tofetch{$assetid} = [ $file, $asset ] ;
  }
  return unless %tofetch;
  my $ntofetch = keys %tofetch;
  print "fetching $ntofetch assets\n";
  # for now assume /ipfs is mounted...
  for my $assetid (sort keys %tofetch) {
    my $file = $tofetch{$assetid}->[0];
    my $url = $tofetch{$assetid}->[1]->{'url'};
    my $digest = $tofetch{$assetid}->[1]->{'digest'};
    die("need a url to download an asset\n") unless $url;
    my $adir = "$assetdir/".substr($assetid, 0, 2);
    PBuild::Util::mkdir_p($adir);
    if (PBuild::Download::download($url, "$adir/.$assetid.$$", undef, 'retry' => 3, 'digest' => $digest, 'missingok' => 1)) {
      rename_unless_present("$adir/.$assetid.$$", "$adir/$assetid");
    }
  }
}

1;
