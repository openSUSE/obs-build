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
use Digest::SHA ();
use MIME::Base64 ();

use Build::Download;

use PBuild::Util;
use PBuild::Cpio;
use PBuild::Zip;

use strict;

#
# Make sure that an asset will be re-fetched. If there is an
# etag, just move the asset so that it can be re-instantiated.
#
sub force_update {
  my ($assetdir, $asset) = @_;
  my $assetid = $asset->{'assetid'};
  my $adir = "$assetdir/".substr($assetid, 0, 2);
  if (-s "$adir/$assetid.etag") {
    rename("$adir/$assetid", "$adir/$assetid.upd");
  } else {
    unlink("$adir/$assetid");
  }
}

#
# Return the etag of an asset. If $renameupd is set, re-instantiate
# an asset that was moved awat by force_update().
#
sub get_etag {
  my ($fn, $etag, $renameupd) = @_;
  my $edata = PBuild::Util::retrieve("$fn.etag", 1);
  if ($edata && $edata->{'etag'} && (!defined($etag) || $edata->{'etag'} eq $etag)) {
    my @s = stat($fn);
    return $edata->{'etag'} if @s && ($edata->{'id'} || '') eq "$s[9]/$s[7]/$s[1]";
    @s = stat("$fn.upd");
    if (@s && ($edata->{'id'} || '') eq "$s[9]/$s[7]/$s[1]") {
      return $edata->{'etag'} if !$renameupd || ($renameupd &&  rename("$fn.upd", $fn));
    }
  }
  return undef;
}

#
# rename a file unless the target already exists
#
sub rename_unless_present {
  my ($old, $new, $etag) = @_;
  if (!$etag) {
    if (!link($old, $new)) {
      die("link $old $new: $!\n") if $! != POSIX::EEXIST;
    } else {
      unlink("$new.etag");
    }
    unlink("$new.upd");
    unlink($old);
    return;
  }
  if (-s "$new.etag" && get_etag($new, $etag, 1)) {
    # no change
    unlink($old);
    return;
  }
  unlink("$new.upd");
  my @s = stat($old);
  die("$old: $!\n") unless @s;
  unlink("$new.etag");
  rename($old, $new) || die("rename $old $new: $!\n");
  my $edata = { 'id' => "$s[9]/$s[7]/$s[1]", 'etag' => $etag };
  PBuild::Util::store("$new.etag.$$", "$new.etag", $edata);
}

#
# create a obscpio asset from a directory
#
sub create_asset_from_dir {
  my ($assetdir, $asset, $dir, $mtime, $etag) = @_;
  my $assetid = $asset->{'assetid'};
  my $adir = "$assetdir/".substr($assetid, 0, 2);
  PBuild::Util::mkdir_p($adir);
  my $fd;
  open($fd, '>', "$adir/.$assetid.$$") || die("$adir/.$assetid.$$: $!");
  PBuild::Cpio::cpio_create($fd, $dir, 'mtime' => $mtime);
  close($fd) || die("$adir/.$assetid.$$: $!");
  rename_unless_present("$adir/.$assetid.$$", "$adir/$assetid", $etag);
}


#
# Recipe file remote asset handling
#
sub recipe_parse {
  my ($p) = @_;
  my @assets;
  for my $s (@{$p->{'remoteassets'} || []}) {
    my $url = $s->{'url'};
    my $digest = $s->{'digest'};
    my $file = $s->{'file'};
    if ($url && $url =~ /^git(?:\+https?)?:.*\/([^\/]+?)(?:\#([^\#\/]+))?$/) {
      my $tag = $2;
      if (!defined($file)) {
	$file = $1;
	$file =~ s/\?.*//;
	$file =~ s/\.git$//;
      }
      next unless defined($file) && $file =~ /^([^\.\/][^\/]+)$/s;
      next if $p->{'files'}->{$file};	# die() instead?
      my $asset = { 'file' => $file, 'url' => $url, 'type' => 'url', 'isdir' => 1 };
      if ($tag =~ /^[0-9a-fA-F]{40,}$/) {
	$asset->{'immutable'} = 1;
	$asset->{'assetid'} = Digest::MD5::md5_hex($url);
      }
      $asset->{'digest'} = $digest if $digest;
      $asset->{'finalfile'} = $s->{'finalfile'} if $s->{'finalfile'} && $s->{'finalfile'} =~ /^([^\.\/][^\/]+)$/s;
      push @assets, $asset;
      next;
    }
    if (($s->{'type'} || '' eq 'webcache')) {
      next unless $url;
      $file = 'build-webcache-'.Digest::SHA::sha256_hex($url);
    }
    next unless $url =~ /(?:^|\/)([^\.\/][^\/]+)$/s;
    if (!defined($file)) {
      $file = $1;
      $file =~ s/\?.*// if $url =~ /^https?:\/\//;
    }
    undef $url unless $url =~ /^https?:\/\/.*\/([^\.\/][^\/]+)$/s;
    next unless $digest || $url;
    next unless defined($file) && $file =~ /^([^\.\/][^\/]+)$/s;
    my $asset = { 'file' => $file };
    $asset->{'digest'} = $digest if $digest;
    $asset->{'url'} = $url if $url;
    $asset->{'type'} = 'url' if $url;
    $asset->{'finalfile'} = $s->{'finalfile'} if $s->{'finalfile'} && $s->{'finalfile'} =~ /^([^\.\/][^\/]+)$/s;
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
  return unless $p->{'files'}->{'go.sum'} && !$p->{'files'}->{'vendor/'};
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
    my $cname = "build-gomodcache";
    my $file = "$cname/$mod";
    $file =~ s/\//:/g;
    my $moddir = $mod;
    $moddir =~ s/\/[^\/]+$//;
    $moddir =~ s/([A-Z])/'!'.lc($1)/ge;
    my $vers = $mod;
    $vers =~ s/.*\///;
    $vers =~ s/([A-Z])/'!'.lc($1)/ge;
    my @filelist = map {"$cname/$moddir/\@v/$vers.$_"} sort keys %$l;
    my $assetid = Digest::MD5::md5_hex($k);
    my $asset = { 'type' => 'golang', 'file' => $file, 'mod' => $mod, 'modprefix' => "$moddir/\@v/$vers.", 'filelist' => \@filelist, 'parts' => $mods{$mod}, 'isdir' => 1, 'immutable' => 1, 'assetid' => $assetid };
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
    my $ctx = Build::Download::digest2ctx("sha256:");
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
  Build::Download::checkdigest($data, $digest);
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
    my $cname = "build-gomodcache";
    my $modprefix = $asset->{'modprefix'};
    PBuild::Util::mkdir_p("$tmpdir/$cname/$1") if $modprefix =~ /(.*)\//;
    my $parts = $asset->{'parts'};
    for my $part (sort keys %$parts) {
      my $proxyurl = "$url/$modprefix$part";
      my $maxsize = $part eq 'zip' ? 500000000 : 16000000;
      Build::Download::download($proxyurl, "$tmpdir/$cname/$modprefix$part", undef, 'retry' => 3, 'maxsize' => $maxsize);
      my $h1 = $parts->{$part};
      verify_golang_h1("$tmpdir/$cname/$modprefix$part", $part, $h1) if defined $h1;
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
    if (Build::Download::download($fedpkg_url, "$adir/.$assetid.$$", undef, 'retry' => 3, 'digest' => $asset->{'digest'}, 'missingok' => 1, 'headers' => [ 'Accept' => '*/*', 'Accept-Encoding' => 'identity' ], 'gzip_retry' => 1)) {
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

sub get_git_commit {
  my ($url, $branch, $tmpdir) = @_;
  my %refs;
  my $fd;
  print "GIT-LS-REMOTE $url".(defined($branch) ? " branch=$branch" : '')."\n" if $Build::Download::debug;
  my @patterns;
  push @patterns, 'HEAD' unless defined $branch;
  push @patterns, 'refs/tags/*', 'refs/heads/*' if defined $branch;
  open($fd, '-|', 'git', '-C', "$tmpdir", 'ls-remote', $url, @patterns) || return undef;
  while (<$fd>) {
    chomp;
    my @s = split('\t', $_, 2);
    $refs{$s[1]} = $s[0] if @s == 2;
  }
  close($fd);
  return $refs{'HEAD'} unless defined $branch;
  return $refs{"refs/heads/$branch"} || $refs{"refs/tags/$branch^{}"};
}

sub fetch_git_asset {
  my ($assetdir, $asset) = @_;
  my $assetid = $asset->{'assetid'};
  my $adir = "$assetdir/".substr($assetid, 0, 2);
  my $file = $asset->{'file'};
  PBuild::Util::mkdir_p($adir);
  my $url = $asset->{'url'};
  die unless $url =~ /^git(?:\+https?)?:/;
  $url =~ s/^git\+//;
  my $branch;
  $branch = $1 if $url =~ s/#([^#]+)$//;
  my $keepmeta;
  if ($url =~ /(.*?)\?(.*)$/) {
    my ($urlpath, $urlquery) = ($1, "&$2&");
    $keepmeta = defined($1) ? $1 : 1 if $urlquery =~ s/\&keepmeta(?:=([01]))?\&/\&/;
    $urlquery =~ s/\&$//;
    $urlquery =~ s/^\&/?/;
    $url = "$urlpath$urlquery";
  }
  my $tmpdir = "$assetdir/.tmpdir.$$";
  PBuild::Util::rm_rf($tmpdir);
  PBuild::Util::mkdir_p($tmpdir);
  my $immutable;
  if ($branch =~ /^[0-9a-fA-F]{40,}$/) {
    print "GIT-CLONE $url commit=$branch\n" if $Build::Download::debug;
    $immutable = 1;
    my $objectformat = length($branch) == 64 ? 'sha256' : 'sha1';
    my @cmd = ('git', 'init', '-q', "--object-format=$objectformat", "$tmpdir/$file");
    system(@cmd) && die("git init failed: $?\n");
    @cmd = ('git', '-C', "$tmpdir/$file", 'remote', 'add', 'origin', $url);
    system(@cmd) && die("git remote failed: $?\n");
    @cmd = ('git', '-C', "$tmpdir/$file", 'fetch', '-q', 'origin', $branch);
    if (system(@cmd)) {
      @cmd = ('git', '-C', "$tmpdir/$file", 'fetch', '-q', 'origin');
      system(@cmd) && die("git fetch failed: $?\n");
    }
    @cmd = ('git', '-C', "$tmpdir/$file", 'checkout', '-q', $branch);
    system(@cmd) && die("git checkout failed: $?\n");
    @cmd = ('git', '-C', "$tmpdir/$file", 'submodule', 'init');
    system(@cmd) && die("git submodule init failed: $?\n");
    @cmd = ('git', '-C', "$tmpdir/$file", 'submodule', 'update', '--recursive');
    system(@cmd) && die("git submodule update failed: $?\n");
  } else {
    my $etag;
    $etag = get_etag("$adir/$assetid") if !$asset->{'donotpack'} && -s "$adir/$assetid.etag";
    if ($etag) {
      my $remoteetag = get_git_commit($url, $branch, $tmpdir);
      if ($remoteetag && get_etag("$adir/$assetid", $remoteetag, 1)) {
        PBuild::Util::rm_rf($tmpdir);
	return;		# no change
      }
    }
    print "GIT-CLONE $url".(defined($branch) ? " branch=$branch" : '')."\n" if $Build::Download::debug;
    my @cmd = ('git', '-c', 'advice.detachedHead=false', 'clone', '-q', '--recurse-submodules');
    push @cmd, '-b', $branch if defined $branch;
    push @cmd, '--', $url, "$tmpdir/$file";
    system(@cmd) && die("git clone failed: $?\n");
  }
  # get timestamp and id of last commit
  my $pfd;
  open($pfd, '-|', 'git', '-C', "$tmpdir/$file", 'log', '--pretty=format:%H %ct', '-1') || die("open: $!\n");
  my $t = <$pfd>;
  close($pfd);
  chomp $t;
  my @t = split(' ', $t);
  my $etag = $t[0] if $t[0] && $t[0] =~ /^[0-9a-fA-F]{40,}$/;
  my $mtime = $t[1] if $t[1] =~ /^\d+$/;
  if ($asset->{'digest'}) {
    die("could not query git commit\n") unless $etag;
    my $commit;
    $commit = "sha1:$etag" if length($etag) == 40;
    $commit = "sha256:$etag" if length($etag) == 64;
    die("unsupported commit algo ($etag)\n") unless $commit;
    die("digest mismatch: $asset->{'digest'}, got $etag\n") unless lc($commit) eq lc($asset->{'digest'});
  }
  $etag = undef if $immutable;	# no need for an etag
  # get rid of .git directory (need to make this optional)
  PBuild::Util::rm_rf("$tmpdir/$file/.git") unless $keepmeta;
  if ($asset->{'donotpack'}) {
    utime($t, $t, "$tmpdir/$file") if defined $t;
    unlink("$adir/$assetid.etag");
    rename("$tmpdir/$file", "$adir/$assetid") || die("rename $tmpdir $adir/$assetid: $!\n");
  } else {
    create_asset_from_dir($assetdir, $asset, $tmpdir, $mtime, $etag);
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
      my $etag;
      $etag = get_etag("$adir/$assetid") if -s "$adir/$assetid.etag";
      my $headers = $etag ? [ 'If-None-Match' => $etag ] : undef;
      my $rh = {};
      my $code = eval { Build::Download::download($asset->{'url'}, "$adir/.$assetid.$$", undef, 'retry' => 3, 'digest' => $asset->{'digest'}, 'missingok' => 1, 'notmodifiedok' => ($etag ? 1 : undef), 'headers' => $headers, 'replyheaders' => \$rh) };
      warn($@) if $@;
      if ($code && $code == 304) {
	next if get_etag("$adir/$assetid", $etag, 1);
	# retry without the If-None-Match header
	undef $etag;
	$code = eval { Build::Download::download($asset->{'url'}, "$adir/.$assetid.$$", undef, 'retry' => 3, 'digest' => $asset->{'digest'}, 'missingok' => 1, 'replyheaders' => \$rh) };
        warn($@) if $@;
      }
      rename_unless_present("$adir/.$assetid.$$", "$adir/$assetid", $rh->{'etag'}) if $code;
    }
  }
}

1;
