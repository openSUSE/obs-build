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
use Digest::MD5 ();
use MIME::Base64 ();

use PBuild::Util;
use PBuild::Download;
use PBuild::Cpio;
use PBuild::Zip;

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
# create a obscpio asset from a directory
#
sub create_asset_from_dir {
  my ($assetdir, $asset, $dir, $mtime) = @_;
  my $assetid = $asset->{'assetid'};
  my $adir = "$assetdir/".substr($assetid, 0, 2);
  PBuild::Util::mkdir_p($adir);
  my $fd;
  open($fd, '>', "$adir/.$assetid.$$") || die("$adir/.$assetid.$$: $!");
  PBuild::Cpio::cpio_create($fd, $dir, 'mtime' => $mtime);
  close($fd) || die("$adir/.$assetid.$$: $!");
  rename_unless_present("$adir/.$assetid.$$", "$adir/$assetid");
}


#
# Recipe file remote asset handling
#
sub recipe_parse {
  my ($p) = @_;
  my @assets;
  for my $s (@{$p->{'remoteassets'} || []}) {
    my $url = $s->{'url'};
    if ($url && $url =~ /^git(?:\+https?)?:.*\/([^\/]+?)(?:.git)?(?:\#[^\#\/]+)?$/) {
      my $file = $1;
      next if $p->{'files'}->{$file};
      push @assets, { 'file' => $file, 'url' => $url, 'type' => 'url', 'isdir' => 1 };
      next;
    }
    next unless $s->{'url'} =~ /(?:^|\/)([^\.\/][^\/]+)$/s;
    my $file = $1;
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

# Go module proxy support

#
# Parse the go.sum file to find module information
#
sub golang_parse {
  my ($p) = @_;
  return unless $p->{'files'}->{'go.sum'};
  my $fd;
  my @assets;
  open ($fd, '<', "$p->{'dir'}/go.sum") || die("$p->{'dir'}/go.sum: $!\n");
  my %mods;
  while (<$fd>) {
    chomp;
    my @s = split(' ', $_);
    next unless @s >= 3;
    next unless $s[1] =~ /^v./;
    next unless $s[2] =~ /^h1:[a-zA-Z0-9\+\/=]+/;
    if ($s[1] =~ s/\/go.mod$//) {
      $mods{"$s[0]/$s[1]"}->{'mod'} = $s[2];
    } else {
      $mods{"$s[0]/$s[1]"}->{'zip'} = $s[2];
      $mods{"$s[0]/$s[1]"}->{'info'} = undef;	# not protected by a checksum
    }
  }
  for my $mod (sort keys %mods) {
    my $l = $mods{$mod};
    next unless $l->{'mod'};	# need at least the go.mod file
    my $k = "$mod";
    $k .= " $_ $mods{$mod}->{$_}" for sort keys %{$mods{$mod}};
    my $file = "build-gomodcache/$mod";
    $file =~ s/\//:/g;
    my $assetid = Digest::MD5::md5_hex($k);
    my $asset = { 'type' => 'golang', 'file' => $file, 'mod' => $mod, 'parts' => $mods{$mod}, 'isdir' => 1, 'immutable' => 1, 'assetid' => $assetid };
    push @assets, $asset;
  }
  close $fd;
  return @assets;
}

#
# Verify a file with the go module h1 checksum
#
sub verify_golang_h1 {
  my ($file, $part, $h1) = @_;
  my $fd;
  open($fd, '<', $file) || die("file: $!\n");
  my %content;
  if ($part eq 'mod') {
    $content{'go.mod'} = {};
  } elsif ($part eq 'zip') {
    my $l = PBuild::Zip::zip_list($fd);
    for (@$l) {
      next if $_->{'ziptype'} != 8;	# only plain files
      die("file $_->{'name'} exceeds size limit\n") if $_->{'size'} >= 500000000;
      $content{$_->{'name'}} = $_;
    }
  }
  die("$file: no content\n") unless %content;
  my $data = '';
  for my $file (sort keys %content) {
    my $ctx = PBuild::Download::digest2ctx("sha256:");
    if ($part eq 'zip') {
      PBuild::Zip::zip_extract($fd, $content{$file}, 'writer' => sub {$ctx->add($_[0])});
    } else {
      my $chunk;
      $ctx->add($chunk) while read($fd, $chunk, 65536);
    }
    $data .= $ctx->hexdigest()."  $file\n";
  }
  close($fd);
  die("not a h1 checksum: $h1\n") unless $h1 =~ /^h1:/;
  my $digest = "sha256:".unpack("H*", MIME::Base64::decode_base64(substr($h1, 3)));
  PBuild::Download::checkdigest($data, $digest);
}

#
# Fetch golang assets from a go module proxy
#
sub golang_fetch {
  my ($p, $assetdir, $assets, $url) = @_;
  my @assets = grep {$_->{'type'} eq 'golang'} @$assets;
  return unless @assets;
  print "fetching ".PBuild::Util::plural(scalar(@assets), 'asset')." from $url\n";
  for my $asset (@assets) {
    my $tmpdir = "$assetdir/.tmpdir.$$";
    PBuild::Util::rm_rf($tmpdir);
    my $mod = $asset->{'mod'};
    my $moddir = $mod;
    $moddir =~ s/\/[^\/]+$//;
    $moddir =~ s/([A-Z])/'!'.lc($1)/ge;
    my $vers = $mod;
    $vers =~ s/.*\///;
    $vers =~ s/([A-Z])/'!'.lc($1)/ge;
    my $cname = "build-gomodcache";
    PBuild::Util::mkdir_p("$tmpdir/$cname/$moddir/\@v");
    my $parts = $asset->{'parts'};
    for my $part (sort keys %$parts) {
      my $proxyurl = "$url/$moddir/\@v/$vers.$part";
      my $maxsize = $part eq 'zip' ? 500000000 : 16000000;
      PBuild::Download::download($proxyurl, "$tmpdir/$cname/$moddir/\@v/$vers.$part", undef, 'retry' => 3, 'maxsize' => $maxsize);
      my $h1 = $parts->{$part};
      verify_golang_h1("$tmpdir/$cname/$moddir/\@v/$vers.$part", $part, $h1) if defined $h1;
    }
    my $mtime = 0;	# we want reproducible cpio archives
    create_asset_from_dir($assetdir, $asset, $tmpdir, $mtime);
    PBuild::Util::rm_rf($tmpdir);
  }
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
  my @assets = grep {$_->{'digest'}} @$assets;
  return unless @assets;
  die("need a parsed name to download fedpkg assets\n") unless $p->{'name'};
  print "fetching ".PBuild::Util::plural(scalar(@assets), 'asset')." from $url\n";
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

# IPFS asset support (parsing is done in the source handler)

#
# Get missing assets from the InterPlanetary File System
#
sub ipfs_fetch {
  my ($p, $assetdir, $assets) = @_;
  my @assets = grep {($_->{'type'} || '') eq 'ipfs'} @$assets;
  return unless @assets;
  print "fetching ".PBuild::Util::plural(scalar(@assets), 'asset')." from the InterPlanetary File System\n";
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

# Generic url asset support

sub fetch_git_asset {
  my ($assetdir, $asset) = @_;
  my $tmpdir = "$assetdir/.tmpdir.$$";
  PBuild::Util::rm_rf($tmpdir);
  PBuild::Util::mkdir_p($tmpdir);
  my $assetid = $asset->{'assetid'};
  my $adir = "$assetdir/".substr($assetid, 0, 2);
  my $file = $asset->{'file'};
  PBuild::Util::mkdir_p($adir);
  my $url = $asset->{'url'};
  die unless $url =~ /^git(?:\+https?)?:/;
  $url =~ s/^git\+//;
  my @cmd = ('git', 'clone', '-q');
  push @cmd, '-b', $1 if $url =~ s/#([^#]+)$//;
  push @cmd, '--', $url, "$tmpdir/$file";
  system(@cmd) && die("git clone failed: $!\n");
  # get timestamp of last commit
  my $pfd;
  open($pfd, '-|', 'git', '-C', "$tmpdir/$file", 'log', '--pretty=format:%ct', '-1') || die("open: $!\n");
  my $t = <$pfd>;
  close($pfd);
  chomp $t;
  $t = undef unless $t && $t > 0;
  if ($asset->{'donotpack'}) {
    rename("$tmpdir/$file", "$adir/$assetid") || die("rename $tmpdir $adir/$assetid: $!\n");
  } else {
    create_asset_from_dir($assetdir, $asset, $tmpdir, $t);
  }
  PBuild::Util::rm_rf($tmpdir);
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
    print "fetching ".PBuild::Util::plural(scalar(@$tofetch), 'asset')." from $hosturl\n";
    for my $asset (@$tofetch) {
      if ($asset->{'url'} =~ /^git(?:\+https?)?:/) {
	fetch_git_asset($assetdir, $asset);
	next;
      }
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
