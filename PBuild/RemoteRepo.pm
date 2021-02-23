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

use Encode;
use IO::Uncompress::Gunzip ();
use Digest::MD5 ();
use Data::Dumper;

use Build;
use Build::Rpmmd;
use Build::Archrepo;
use Build::Debrepo;
use Build::Deb;
use Build::Susetags;
use Build::Zypp;

use PBuild::Util;
use PBuild::Download;
use PBuild::Verify;
use PBuild::Cpio;
use PBuild::OBS;

my @binsufs = qw{rpm deb pkg.tar.gz pkg.tar.xz pkg.tar.zst};
my $binsufsre = join('|', map {"\Q$_\E"} @binsufs);

sub download_zypp {
  my ($url, $dest, $digest) = @_;
  die("do not know how to download $url\n") unless $url =~ m#^zypp://([^/]+)/((?:.*/)?([^/]+)\.rpm)$#;
  my ($repo, $path, $pkg) = ($1, $2, $3);
  die("bad dest $dest for $pkg\n") if $dest !~ /^(.*)\/[^\/]*\Q$pkg\E\.rpm$/;
  my $dir = $1;
  system('/usr/bin/zypper', '--no-refresh', '-q', '--pkg-cache-dir', $dir, 'download', '-r', $repo, $pkg)
      && die("zypper download $pkg failed\n");
  die("zypper download of $pkg did not create $dir/$repo/$path\n") unless -f "$dir/$repo/$path";
  PBuild::Download::checkfiledigest("$dir/$repo/$path", $digest) if $digest;
  rename("$dir/$repo/$path", $dest) || die("rename $dir/$repo/$path $dest: $!\n");
}

sub download {
  my ($url, $dest, $destfinal, $digest, $ua) = @_;
  return download_zypp($url, $destfinal || $dest, $digest) if $url =~ /^zypp:\/\//;
  PBuild::Download::download($url, $dest, $destfinal, 'digest' => $digest, 'ua' => $ua, 'retry' => 3);
}

sub addpkg {
  my ($bins, $pkg, $locprefix) = @_;
  return unless defined($pkg->{'name'}) && defined($pkg->{'arch'});
  return if $pkg->{'arch'} eq 'src' || $pkg->{'arch'} eq 'nosrc';
  $locprefix = '' unless defined $locprefix;
  $pkg->{'location'} = "$locprefix$pkg->{'location'}" if defined $locprefix;
  delete $pkg->{'filename'};	# just in case
  delete $pkg->{'packid'};	# just in case
  push @$bins, $pkg;
}

sub fetchrepo_arch {
  my ($url, $tmpdir, $arch) = @_;
  die("could not determine reponame from url $url\n") unless "/$url/" =~ /.*\/([^\/]+)\/os\//;
  my $reponame = $1;
  $url .= '/' unless $url =~ /\/$/;
  download("$url$reponame.db", "$tmpdir/repo.db");
  my @bins;
  Build::Archrepo::parse("$tmpdir/repo.db", sub { addpkg(\@bins, $_[0], $url) }, 'addselfprovides' => 1);
  return \@bins;
}

sub fetchrepo_debian {
  my ($url, $tmpdir, $arch) = @_;
  my ($baseurl, $disturl, $components) = Build::Debrepo::parserepourl($url);
  my $basearch = Build::Deb::basearch($arch);
  my @bins;
  for my $component (@$components) {
    unlink("$tmpdir/Packages.gz");
    if ($component eq '.') {
      download("${disturl}Packages.gz", "$tmpdir/Packages.gz");
      die("Packages.gz missing\n") unless -s "$tmpdir/Packages.gz";
    } else {
      download("$disturl$component/binary-$basearch/Packages.gz", "$tmpdir/Packages.gz");
      die("Packages.gz missing for basearch $basearch, component $component\n") unless -s "$tmpdir/Packages.gz";
    }
    Build::Debrepo::parse("$tmpdir/Packages.gz", sub { addpkg(\@bins, $_[0], $url) }, 'addselfprovides' => 1, 'withchecksum' => 1);
  }
  return \@bins;
}

sub fetchrepo_rpmmd {
  my ($url, $tmpdir, $arch, $iszypp) = @_;
  my $baseurl = $url;
  $baseurl .= '/' unless $baseurl =~ /\/$/;
  my @primaryfiles;
  download("${baseurl}repodata/repomd.xml", "$tmpdir/repomd.xml") unless $iszypp;
  Build::Rpmmd::parse_repomd("$tmpdir/repomd.xml", \@primaryfiles);
  @primaryfiles = grep {$_->{'type'} eq 'primary' && defined($_->{'location'})} @primaryfiles;
  my @bins;
  for my $f (@primaryfiles) {
    my $u = "$f->{'location'}";
    utf8::downgrade($u);
    next unless $u =~ /(primary\.xml(?:\.gz)?)$/;
    my $fn = $1;
    if ($iszypp) {
      $fn = $u;
      $fn =~ s/.*\///s;
      die("zypp repo $url is not up to date, please refresh first\n") unless -s "$tmpdir/$fn";
    } else {
      die("primary file $u does not have a checksum\n") unless $f->{'checksum'} && $f->{'checksum'} =~ /:(.*)/;
      $fn = "$1-$fn";
      download("${baseurl}/$f->{'location'}", "$tmpdir/$fn", undef, $f->{'checksum'});
    }
    my $fh;
    open($fh, '<', "$tmpdir/$fn") or die "Error opening $tmpdir/$fn: $!\n";
    if ($fn =~ /\.gz$/) {
      $fh = IO::Uncompress::Gunzip->new($fh) or die("Error opening $u: $IO::Uncompress::Gunzip::GunzipError\n");
    }
    Build::Rpmmd::parse($fh, sub { addpkg(\@bins, $_[0], $baseurl) }, 'addselfprovides' => 1, 'withchecksum' => 1);
    last;
  }
  return \@bins;
}

sub fetchrepo_susetags {
  my ($url, $tmpdir, $arch, $iszypp) = @_;
  my $descrdir = 'suse/setup/descr';
  my $datadir = 'suse';
  my $baseurl = $url;
  $baseurl .= '/' unless $baseurl =~ /\/$/;
  download("${baseurl}$descrdir/packages.gz", "$tmpdir/packages.gz") unless $iszypp;
  my @bins;
  Build::Susetags::parse("$tmpdir/packages.gz", sub {
    my $xurl = $baseurl;
    $xurl =~ s/1\/$/$_[0]->{'medium'}/ if $_[0]->{'medium'};
    $xurl .= "$datadir/" if $datadir;
    addpkg(\@bins, $_[0], $xurl)
  }, 'addselfprovides' => 1, 'withchecksum' => 1);
  return \@bins;
}

sub fetchrepo_zypp {
  my ($url, $tmpdir, $arch) = @_;
  die("zypp repo must start with zypp://\n") unless $url =~ /^zypp:\/\/([^\/]*)/;
  my $repo = Build::Zypp::parserepo($1);
  my $type = $repo->{'type'};
  my $zyppcachedir = "/var/cache/zypp/raw/$repo->{'name'}";
  if (!$type) {
    $type = 'yast2' if -e "$zyppcachedir/suse/setup/descr";
    $type = 'rpm-md' if -e "$zyppcachedir/repodata";
  }
  die("could not determine repo type for '$repo->{'name'}'\n") unless $type;
  if($type eq 'rpm-md') {
    die("zypp repo $url is not up to date, please refresh first\n") unless -s "$zyppcachedir/repodata/repomd.xml";
    fetchrepo_rpmmd("zypp://$repo->{'name'}", "$zyppcachedir/repodata", $arch, 1);
  } else {
    die("zypp repo $url is not up to date, please refresh first\n") unless -s "$zyppcachedir/suse/setup/descr/packages.gz";
    fetchrepo_susetags("zypp://$repo->{'name'}", "$zyppcachedir/suse/setup/descr", $arch, 1);
  }
}

sub fetchrepo_obs {
  my ($url, $tmpdir, $arch, $opts) = @_;
  die("bad obs: reference\n") unless $url =~ /^obs:\/{1,3}([^\/]+\/[^\/]+)\/?$/;
  my $prp = $1;
  die("please specify the build service url with the --obs option\n") unless $opts->{'obs'};
  my $baseurl = $opts->{'obs'};
  $baseurl .= '/' unless $baseurl =~ /\/$/;
  download("${baseurl}build/$prp/$arch/_repository?view=cache", "$tmpdir/repository.cpio");
  PBuild::Cpio::cpio_extract("$tmpdir/repository.cpio", 'repositorycache', "$tmpdir/repository.data");
  my $rdata = PBuild::Util::retrieve("$tmpdir/repository.data");
  my @bins = grep {ref($_) eq 'HASH' && defined($_->{'name'})} values %{$rdata || {}};
  @bins = sort {$a->{'name'} cmp $b->{'name'}} @bins;
  for (@bins) {
    delete $_->{'filename'};	# just in case
    delete $_->{'packid'};	# just in case
    if ($_->{'path'} =~ /^\.\.\/([^\/\.][^\/]*\/[^\/\.][^\/]*)$/s) {
      $_->{'location'} = "${baseurl}build/$prp/$arch/$1";	# obsbinlink to package
    } else {
      $_->{'location'} = "${baseurl}build/$prp/$arch/_repository/$_->{'path'}";
    }
    PBuild::OBS::recode_deps($_);	# recode deps from testcase format to rpm
  }
  return \@bins;
}

#
# Generate the on-disk filename from the metadata
#
sub calc_binname {
  my ($bin) = @_;
  my $suf;
  if ($bin->{'name'} =~ /^container:/) {
    $suf = 'tar';
  } else {
    die("bad location: $bin->{'location'}\n") unless $bin->{'location'} =~ /\.($binsufsre)$/;
    $suf = $1;
  }
  my $binname = $bin->{'version'};
  $binname = "$bin->{'epoch'}:$binname" if $bin->{'epoch'};
  $binname .= "-$bin->{'release'}" if defined $bin->{'release'};
  $binname .= ".$bin->{'arch'}" if $bin->{'arch'};
  $binname = "$bin->{'name'}-$binname.$suf";
  $binname = "$bin->{'hdrmd5'}-$binname" if $binname =~ s/^container:// && $bin->{'hdrmd5'};
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
    if ($bin->{'name'} =~ /^container:/) {
      delete $bin->{'id'};
      $bin->{'filename'} = $file;
      next;
    }
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
  my ($bconf, $arch, $repodir, $url, $buildtype, $opts) = @_;
  my $repotype;
  $repotype = 'zypp' if $url =~ /^zypp:/;
  $repotype = 'obs' if $url =~ /^obs:/;
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
  } elsif ($repotype eq 'suse') {
    $bins = fetchrepo_susetags($url, $tmpdir, $arch);
  } elsif ($repotype eq 'zypp') {
    $bins = fetchrepo_zypp($url, $tmpdir, $arch);
  } elsif ($repotype eq 'obs') {
    $bins = fetchrepo_obs($url, $tmpdir, $arch, $opts);
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
    die("missing location for binary $bin->{'name'}\n") unless $location;
    die("bad location: $location\n") unless $location =~ /^(?:https?|zypp):\/\//;
    my $binname = calc_binname($bin);
    PBuild::Verify::verify_filename($binname);
    next if -e "$repodir/$binname";		# hey!
    my $tmpname = ".$$.$binname";
    if ($bin->{'name'} =~ /^container:/) {
      # we cannot query containers, just download and set the filename
      die("container has no hdrmd5\n") unless $bin->{'hdrmd5'};
      download($location, "$repodir/$tmpname", "$repodir/$binname", "md5:$bin->{'hdrmd5'}", $ua);
      delete $bin->{'id'};
      $bin->{'filename'} = $binname;
      next;
    }
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
