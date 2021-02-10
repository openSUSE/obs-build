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

package PBuild::RemoteRepo;

use strict;

use LWP::UserAgent;
use URI;
use Encode;
use IO::Uncompress::Gunzip ();
use Digest::MD5 ();
use Data::Dumper;

use Build;
use Build::Rpmmd;
use Build::Archrepo;
use Build::Debrepo;
use Build::Deb;

use PBuild::Util;
use PBuild::Download;
use PBuild::Verify;

my @binsufs = qw{rpm deb pkg.tar.gz pkg.tar.xz pkg.tar.zst};
my $binsufsre = join('|', map {"\Q$_\E"} @binsufs);

sub download_zypp {
  my ($url, $dest, $digest);
  die("do not know how to download $url\n") unless $url =~ m#^zypp://([^/]+)/((?:.*/)?([^/]+)\.rpm)$#;
  my ($repo, $path, $pkg) = ($1, $2, $3);
  die("bad dest $dest\n") if $dest !~ /^(.*)\/\Q$pkg\E\.rpm$/;
  my $dir = $1;
  system('/usr/bin/zypper', '--no-refresh', '-q', '--pkg-cache-dir', $dir, 'download', '-r', $repo, $pkg)
      && die("zypper download $pkg failed\n");
  die("zypper download of $pkg did not create $dir/$repo/$path\n") unless -f "$dir/$repo/$path";
  PBuild::Download::checkdigest("$dir/$repo/$path", $digest) if $digest;
  rename("$dir/$repo/$path", $dest) || die("rename $dir/$repo/$path $dest: $!\n");
}

sub download {
  my ($url, $dest, $destfinal, $digest, $ua) = @_;
  return download_zypp($url, $destfinal || $dest, $digest) if $url =~ /^zypp:\/\//;
  PBuild::Download::download($url, $dest, $destfinal, $digest, $ua, 3);
}

sub addpkg {
  my ($repodata, $pkg, $locprefix) = @_;
  return unless defined($pkg->{'name'}) && defined($pkg->{'arch'});
  return if $pkg->{'arch'} eq 'src' || $pkg->{'arch'} eq 'nosrc';
  $locprefix = '' unless defined $locprefix;
  $pkg->{'location'} = "$locprefix$pkg->{'location'}" if defined $locprefix;
  delete $pkg->{'filename'};	# just in case
  push @$repodata, $pkg;
}

sub fetchrepo_arch {
  my ($url, $tmpdir, $arch) = @_;
  die("could not determine reponame from url $url\n") unless "/$url/" =~ /.*\/([^\/]+)\/os\//;
  my $reponame = $1;
  $url .= '/' unless $url =~ /\/$/;
  download("$url$reponame.db", "$tmpdir/repo.db");
  my @repodata;
  Build::Archrepo::parse("$tmpdir/repo.db", sub { addpkg(\@repodata, $_[0], $url) }, 'addselfprovides' => 1);
  return \@repodata;
}

sub fetchrepo_debian {
  my ($url, $tmpdir, $arch) = @_;
  my ($baseurl, $disturl, $components) = Build::Debrepo::parserepourl($url);
  my $basearch = Build::Deb::basearch($arch);
  my @repodata;
  for my $component (@$components) {
    unlink("$tmpdir/Packages.gz");
    if ($component eq '.') {
      download("${disturl}Packages.gz", "$tmpdir/Packages.gz");
      die("Packages.gz missing\n") unless -s "$tmpdir/Packages.gz";
    } else {
      download("$disturl$component/binary-$basearch/Packages.gz", "$tmpdir/Packages.gz");
      die("Packages.gz missing for basearch $basearch, component $component\n") unless -s "$tmpdir/Packages.gz";
    }
    Build::Debrepo::parse("$tmpdir/Packages.gz", sub { addpkg(\@repodata, $_[0], $url) }, 'addselfprovides' => 1);
  }
  return \@repodata;
}

sub fetchrepo_rpmmd {
  my ($url, $tmpdir, $arch) = @_;
  my $baseurl = $url;
  my @primaryfiles;
  $baseurl .= '/' unless $baseurl =~ /\/$/;
  download("${baseurl}repodata/repomd.xml", "$tmpdir/repomd.xml");
  Build::Rpmmd::parse_repomd("$tmpdir/repomd.xml", \@primaryfiles);
  @primaryfiles = grep {$_->{'type'} eq 'primary' && defined($_->{'location'})} @primaryfiles;
  my @repodata;
  for my $f (@primaryfiles) {
    my $u = "$f->{'location'}";
    utf8::downgrade($u);
    next unless $u =~ /(primary\.xml(?:\.gz)?)$/;
    my $fn = $1;
    download("${baseurl}/$f->{'location'}", "$tmpdir/$fn", undef, $f->{'checksum'});
    my $fh;
    open($fh, '<', "$tmpdir/$fn") or die "Error opening $tmpdir/$fn: $!\n";
    if ($fn =~ /\.gz$/) {
      $fh = IO::Uncompress::Gunzip->new($fh) or die("Error opening $u: $IO::Uncompress::Gunzip::GunzipError\n");
    }
    Build::Rpmmd::parse($fh, sub { addpkg(\@repodata, $_[0], $url) }, 'addselfprovides' => 1);
    last;
  }
  return \@repodata;
}

#
# Generate the on-disk filename from the metadata
#
sub calc_binname {
  my ($bin) = @_;
  die("bad location: $bin->{'location'}\n") unless $bin->{'location'} =~ /\.($binsufsre)$/;
  my $suf = $1;
  my $binname = $bin->{'version'};
  $binname = "$bin->{'epoch'}:$binname" if $bin->{'epoch'};
  $binname .= "-$bin->{'release'}" if defined $bin->{'release'};
  $binname = "$bin->{'name'}-$binname.$suf";
  return $binname;
}

#
# Replace already downloaded entries in the metadata
#
sub replace_with_local {
  my ($repodir, $bins) = @_;
  my $bad;
  my %files = map {$_ => 1} PBuild::Util::ls($repodir);
  delete $files{'_metadata'};
  delete $files{'.tmp'};
  for my $bin (@$bins) {
    my $file = $bin->{'filename'};
    if (defined $file) {
      if (!$files{$file}) {
	$bad = 1;
	next;
      }
      $files{$file} = 2;
      next;
    }
    $file = calc_binname($bin);
    next unless $files{$file};
    eval {
      my $q = querybinary($repodir, $file);
      %$bin = %$q;
      $files{$file} = 2;
    };
    if ($@) {
      warn($@);
      unlink($file);
    }
  }
  for my $file (grep {$files{$_} == 1} sort keys %files) {
    unlink("$repodir/$file");
  }
  return $bad ? 0 : 1;
}

#
# Guess the repotype from the build config
#
sub guess_repotype {
  my ($bconf, $buildtype) = @_;
  return undef unless $bconf;
  for (@{$bconf->{'repotype'} || []}) {
    return $_ if $_ eq 'arch' || $_ eq 'debian' || $_ eq 'hdlist2' || $_ eq 'rpm-md';
  }
  return 'arch' if ($bconf->{'binarytype'} || '') eq 'arch';
  return 'debian' if ($bconf->{'binarytype'} || '') eq 'deb';
  $buildtype ||= $bconf->{'type'};
  return 'rpm-md' if ($buildtype || '') eq 'spec';
  return 'debian' if ($buildtype || '') eq 'dsc';
  return 'arch' if ($buildtype || '') eq 'arch';
  return undef;
}

#
# Get repository metadata for a remote repository
#
sub fetchrepo {
  my ($bconf, $arch, $repodir, $url, $buildtype) = @_;
  my $repotype;
  if ($url =~ /^(arch|debian|hdlist2|rpmmd|rpm-md|suse)\@(.*)$/) {
    $repotype = $1;
    $url = $2;
  }
  $repotype ||= guess_repotype($bconf, $buildtype) || 'rpmmd';
  my $tmpdir = "$repodir/.tmp";
  PBuild::Util::cleandir($tmpdir) if -e $tmpdir;
  PBuild::Util::mkdir_p($tmpdir);
  my $bins;
  my $repofile = "$repodir/_metadata";
  if (-s $repofile) {
    $bins = PBuild::Util::retrieve($repofile, 1);
    return $bins if $bins && replace_with_local($repodir, $bins);
  }
  if ($repotype eq 'rpmmd' || $repotype eq 'rpm-md') {
    $bins = fetchrepo_rpmmd($url, $tmpdir, $arch);
  } elsif ($repotype eq 'debian') {
    $bins = fetchrepo_debian($url, $tmpdir, $arch);
  } elsif ($repotype eq 'arch') {
    $bins = fetchrepo_arch($url, $tmpdir, $arch);
  } else {
    die("unsupported repotype '$repotype'\n");
  }
  die unless $bins;
  replace_with_local($repodir, $bins);
  PBuild::Util::store("$repodir/._metadata.$$", $repofile, $bins);
  return $bins;
}

#
# Check if the downloaded package matches the repository metadata
#
sub is_matching_binary {
  my ($b1, $b2) = @_;
  return 0 if $b1->{'name'} ne $b2->{'name'};
  return 0 if $b1->{'arch'} ne $b2->{'arch'};
  return 0 if $b1->{'version'} ne $b2->{'version'};
  return 0 if ($b1->{'epoch'} || 0) ne ($b2->{'epoch'} || 0);
  return 0 if (defined $b1->{'release'} ? $b1->{'release'} : '__undef__') ne (defined $b2->{'release'} ? $b2->{'release'} : '__undef__');
  return 1;
}

#
# Query dependencies of a downloaded binary package
#
sub querybinary {
  my ($dir, $file) = @_;
  my @s = stat("$dir/$file");
  die("$dir/$file: $!\n") unless @s;
  my $id = "$s[9]/$s[7]/$s[1]";
  my $data;
  my $leadsigmd5;
  die("$dir/$file: no hdrmd5\n") unless Build::queryhdrmd5("$dir/$file", \$leadsigmd5);
  $data = Build::query("$dir/$file", 'evra' => 1, 'conflicts' => 1, 'weakdeps' => 1, 'addselfprovides' => 1, 'filedeps' => 1);
  die("$dir/$file: query failed\n") unless $data;
  PBuild::Verify::verify_nevraquery($data);
  $data->{'leadsigmd5'} = $leadsigmd5 if $leadsigmd5;
  $data->{'filename'} = $file;
  $data->{'id'} = $id;
  return $data;
}

#
# Download missing binaries from a remote repository
#
sub fetchbinaries {
  my ($repo, $bins) = @_;
  my $repodir = $repo->{'dir'};
  my $url = $repo->{'url'};
  my $nbins = @$bins;
  die("bad repo\n") unless $url;
  print "fetching $nbins binaries from $url\n";
  PBuild::Util::mkdir_p($repodir);
  my $ua = PBuild::Download::create_ua();
  for my $bin (@$bins) {
    my $location = $bin->{'location'};
    print Dumper($bin) unless $location;
    die("missing location for binary $bin->{'name'}\n") unless $location;
    die("bad location: $location\n") unless $location =~ /^(?:https?|zypp):\/\//;
    my $binname = calc_binname($bin);
    next if -e "$repodir/$binname";		# hey!
    my $tmpname = ".$$.$binname";
    download($location, "$repodir/$tmpname", undef, $bin->{'checksum'}, $ua);
    my $q = querybinary($repodir, $tmpname);
    die("downloaded binary $binname does not match repository metadata\n") unless is_matching_binary($bin, $q);
    rename("$repodir/$tmpname", "$repodir/$binname") || die("rename $repodir/$tmpname $repodir/$binname\n");
    $q->{'filename'} = $binname;
    # inline replace!
    $q->{'repono'} = $bin->{'repono'} if defined $bin->{'repono'};
    %$bin = %$q;
  }
  # update _metadata
  my $newbins = PBuild::Util::clone($repo->{'bins'});
  delete $_->{'repono'} for @$newbins;
  PBuild::Util::store("$repodir/._metadata.$$", "$repodir/_metadata", $newbins);
}

1;
