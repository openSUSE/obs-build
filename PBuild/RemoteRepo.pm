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

use Build;
use Build::Rpmmd;
use Build::Archrepo;
use Build::Debrepo;
use Build::Deb;
use Build::Susetags;
use Build::Zypp;
use Build::Modules;

use PBuild::Util;
use PBuild::Download;
use PBuild::Verify;
use PBuild::OBS;
use PBuild::Cando;

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
  my ($bins, $pkg, $locprefix, $archfilter) = @_;
  return unless defined($pkg->{'name'}) && defined($pkg->{'arch'});
  return if $pkg->{'arch'} eq 'src' || $pkg->{'arch'} eq 'nosrc';
  return if $archfilter && !$archfilter->{$pkg->{'arch'}};
  $locprefix = '' unless defined $locprefix;
  $pkg->{'location'} = "$locprefix$pkg->{'location'}" if defined $locprefix;
  delete $pkg->{'filename'};	# just in case
  delete $pkg->{'packid'};	# just in case
  push @$bins, $pkg;
}

sub fetchrepo_arch {
  my ($url, $tmpdir, %opts) = @_;
  die("could not determine reponame from url $url\n") unless "/$url/" =~ /.*\/([^\/]+)\/os\//;
  my $reponame = $1;
  $url .= '/' unless $url =~ /\/$/;
  download("$url$reponame.db", "$tmpdir/repo.db");
  my @bins;
  Build::Archrepo::parse("$tmpdir/repo.db", sub { addpkg(\@bins, $_[0], $url) }, 'addselfprovides' => 1);
  return \@bins;
}

sub fetchrepo_debian {
  my ($url, $tmpdir, %opts) = @_;
  my ($baseurl, $disturl, $components) = Build::Debrepo::parserepourl($url);
  die("fetchrepo_debian needs an architecture\n") unless $opts{'arch'};
  my $basearch = Build::Deb::basearch($opts{'arch'});
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

sub open_uncompressed {
  my ($filename) = @_;
  my $fh;
  open($fh, '<', $filename) or die("Error opening $filename: $!\n");
  if ($filename =~ /\.gz$/) {
    $fh = IO::Uncompress::Gunzip->new($fh) or die("Error opening $filename: $IO::Uncompress::Gunzip::GunzipError\n");
  }
  return $fh;
}

sub fetchrepo_rpmmd {
  my ($url, $tmpdir, %opts) = @_;
  my $baseurl = $url;
  $baseurl .= '/' unless $baseurl =~ /\/$/;
  my @resources;
  download("${baseurl}repodata/repomd.xml", "$tmpdir/repomd.xml") unless $opts{'iszypp'};
  my $cookie = Digest::MD5::md5_hex(PBuild::Util::readstr("$tmpdir/repomd.xml"));
  my $oldrepo = $opts{'oldrepo'};
  return $oldrepo if $oldrepo && $oldrepo->{'cookie'} && $cookie eq $oldrepo->{'cookie'};
  Build::Rpmmd::parse_repomd("$tmpdir/repomd.xml", \@resources);
  my @primaryfiles = grep {$_->{'type'} eq 'primary' && defined($_->{'location'})} @resources;
  my $archfilter = $opts{'archfilter'};
  my @bins;
  for my $f (@primaryfiles) {
    my $u = "$f->{'location'}";
    utf8::downgrade($u);
    next unless $u =~ /(primary\.xml(?:\.gz)?)$/s;
    my $fn = $1;
    if ($opts{'iszypp'}) {
      $fn = $u;
      $fn =~ s/.*\///s;
      die("zypp repo $url is not up to date, please refresh first\n") unless -s "$tmpdir/$fn";
    } else {
      die("primary file $u does not have a checksum\n") unless $f->{'checksum'} && $f->{'checksum'} =~ /:(.*)/;
      $fn = "$1-$fn";
      download("${baseurl}/$f->{'location'}", "$tmpdir/$fn", undef, $f->{'checksum'});
    }
    my $fh = open_uncompressed("$tmpdir/$fn");
    Build::Rpmmd::parse($fh, sub { addpkg(\@bins, $_[0], $baseurl, $archfilter) }, 'addselfprovides' => 1, 'withchecksum' => 1);
    last;
  }
  my @moduleinfofiles = grep {$_->{'type'} eq 'modules' && defined($_->{'location'})} @resources;
  for my $f (@moduleinfofiles) {
    my $u = "$f->{'location'}";
    utf8::downgrade($u);
    next unless $u =~ /(modules\.yaml(?:\.gz)?)$/s;
    my $fn = $1;
    die("zypp:// repos do not support module data\n") if $opts{'iszypp'};
    die("modules file $u does not have a checksum\n") unless $f->{'checksum'} && $f->{'checksum'} =~ /:(.*)/;
    $fn = "$1-$fn";
    download("${baseurl}/$f->{'location'}", "$tmpdir/$fn", undef, $f->{'checksum'});
    my $fh = open_uncompressed("$tmpdir/$fn");
    my $moduleinfo = {};
    Build::Modules::parse($fh, $moduleinfo);
    push @bins, { 'name' => 'moduleinfo:', 'data' => $moduleinfo };
    last;
  }
  return { 'bins' => \@bins, 'cookie' => $cookie };
}

sub fetchrepo_susetags {
  my ($url, $tmpdir, %opts) = @_;
  my $descrdir = 'suse/setup/descr';
  my $datadir = 'suse';
  my $baseurl = $url;
  $baseurl .= '/' unless $baseurl =~ /\/$/;
  download("${baseurl}$descrdir/packages.gz", "$tmpdir/packages.gz") unless $opts{'iszypp'};
  my $archfilter = $opts{'archfilter'};
  my @bins;
  Build::Susetags::parse("$tmpdir/packages.gz", sub {
    my $xurl = $baseurl;
    $xurl =~ s/1\/$/$_[0]->{'medium'}/ if $_[0]->{'medium'};
    $xurl .= "$datadir/" if $datadir;
    addpkg(\@bins, $_[0], $xurl, $archfilter)
  }, 'addselfprovides' => 1, 'withchecksum' => 1);
  return \@bins;
}

sub fetchrepo_zypp {
  my ($url, $tmpdir, %opts) = @_;
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
    return fetchrepo_rpmmd("zypp://$repo->{'name'}", "$zyppcachedir/repodata", %opts, 'iszypp' => 1);
  } else {
    die("zypp repo $url is not up to date, please refresh first\n") unless -s "$zyppcachedir/suse/setup/descr/packages.gz";
    return fetchrepo_susetags("zypp://$repo->{'name'}", "$zyppcachedir/suse/setup/descr", %opts, 'iszypp' => 1);
  }
}

sub fetchrepo_obs {
  my ($url, $tmpdir, %opts) = @_;
  my $modules = $opts{'modules'};
  my $bins = PBuild::OBS::fetch_repodata($url, $tmpdir, $opts{'arch'}, $opts{'opts'}, $modules);
  @$bins = sort {$a->{'name'} cmp $b->{'name'}} @$bins;
  for (@$bins) {
    delete $_->{'filename'};	# just in case
    delete $_->{'packid'};	# just in case
  }
  push @$bins, { 'name' => 'moduleinfo:', 'modules' => $modules } if @{$modules || []};
  return $bins;
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
    next if $bin->{'name'} eq 'moduleinfo:';
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
  my $archfilter;
  if ($url =~ /^(arch|debian|hdlist2|rpmmd|rpm-md|suse)(?:\+archfilter=([^\@\/]+))?\@(.*)$/) {
    $repotype = $1;
    $archfilter = [ split(',', $2) ] if $2;
    $url = $3;
  }
  $repotype ||= guess_repotype($bconf, $buildtype) || 'rpmmd';
  $archfilter ||= [ PBuild::Cando::archfilter($arch) ] if $repotype ne 'obs';
  if ($archfilter) {
    $archfilter = { map {$_ => 1} @$archfilter };
    $archfilter->{$_} = 1 for qw{all any noarch};
  }
  my $modules = [ PBuild::Util::unify(sort(@{$bconf->{'modules'} || []})) ];
  my $repofile = "$repodir/_metadata";
  my $cookie;
  my $oldrepo;
  if (-s $repofile) {
    $oldrepo = PBuild::Util::retrieve($repofile, 1);
    undef $oldrepo unless ref($oldrepo) eq 'HASH' && $oldrepo->{'bins'};
    if ($oldrepo && $repotype eq 'obs') {
      # obs repo data changes with the modules, so be careful
      my $oldbins = $oldrepo->{'bins'};
      my $repomodules = [];
      if (@$oldbins && $oldbins->[-1]->{'name'} eq 'moduleinfo:') {
        $repomodules = $oldbins->[-1]->{'modules'} || [];
      }
      undef $oldrepo if join(',', @$modules) ne join(',', @$repomodules);
    }
    undef $oldrepo if $oldrepo && !replace_with_local($repodir, $oldrepo->{'bins'});
    return $oldrepo->{'bins'} if $oldrepo && $opts->{'no-repo-refresh'};
  }
  my $tmpdir = "$repodir/.tmp";
  PBuild::Util::cleandir($tmpdir) if -e $tmpdir;
  PBuild::Util::mkdir_p($tmpdir);
  my $repo;
  my %opts = ( 'arch' => $arch, 'archfilter' => $archfilter, 'modules' => $modules, 'oldrepo' => $oldrepo , 'opts' => $opts);
  if ($repotype eq 'rpmmd' || $repotype eq 'rpm-md') {
    $repo = fetchrepo_rpmmd($url, $tmpdir, %opts);
  } elsif ($repotype eq 'debian') {
    $repo = fetchrepo_debian($url, $tmpdir, %opts);
  } elsif ($repotype eq 'arch') {
    $repo = fetchrepo_arch($url, $tmpdir, %opts);
  } elsif ($repotype eq 'suse') {
    $repo = fetchrepo_susetags($url, $tmpdir, %opts);
  } elsif ($repotype eq 'zypp') {
    $repo = fetchrepo_zypp($url, $tmpdir, %opts);
  } elsif ($repotype eq 'obs') {
    $repo = fetchrepo_obs($url, $tmpdir, %opts);
  } else {
    die("unsupported repotype '$repotype'\n");
  }
  $repo = { 'bins' => $repo } if $repo && ref($repo) ne 'HASH';
  die unless $repo && $repo->{'bins'};
  replace_with_local($repodir, $repo->{'bins'}) unless $repo == $oldrepo;
  PBuild::Util::store("$repodir/._metadata.$$", $repofile, $repo);
  return $repo->{'bins'};
}

#
# Expand the special zypp:// repo to all enabled zypp repositories
#
sub expand_zypp_repo {
  my ($repos) = @_;
  return unless grep {/^zypp:\/{0,2}$/} @{$repos || []};
  my @r;
  for my $url (@$repos) {
    if ($url =~ /^zypp:\/{0,2}$/) {
      for my $r (Build::Zypp::parseallrepos()) {
        push @r, "zypp://$r->{'name'}" if $r->{'enabled'};
      }
    } else {
      push @r, $url;
    }
  }
  @$repos = @r;
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
# Check if the downloaded binary matches and replace the stub with it
#
sub fetchbinaries_replace {
  my ($repodir, $tmpname, $binname, $bin) = @_;
  PBuild::Download::checkfiledigest("$repodir/$tmpname", $bin->{'checksum'}) if $bin->{'checksum'};
  my $q = querybinary($repodir, $tmpname);
  die("downloaded binary $binname does not match repository metadata\n") unless is_matching_binary($bin, $q);
  rename("$repodir/$tmpname", "$repodir/$binname") || die("rename $repodir/$tmpname $repodir/$binname\n");
  $q->{'filename'} = $binname;
  %$bin = %$q;	# inline replace!
}

#
# Download missing binaries in batches from a remote obs instance
#
sub fetchbinaries_obs {
  my ($repo, $bins, $ua) = @_;
  my $url;
  my %names;
  for my $bin (@$bins) {
    next if $bin->{'filename'};
    my $location = $bin->{'location'};
    die("missing location for binary $bin->{'name'}\n") unless $location;
    next if $location =~ /^zypp:/ || $location !~ /(.+)\/_repository\//;
    my $binname = calc_binname($bin);
    PBuild::Verify::verify_filename($binname);
    $url = $1 unless defined $url;
    next if $1 ne $url;
    $names{$bin->{'name'}} = [ ".$$.$binname", $binname, $bin ];
  }
  return unless %names;
  my $repodir = $repo->{'dir'};
  PBuild::Util::mkdir_p($repodir);
  PBuild::OBS::fetch_binaries($url, $repodir, \%names, \&fetchbinaries_replace, $ua);
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
  fetchbinaries_obs($repo, $bins, $ua) if $url =~ /^obs:/;
  for my $bin (@$bins) {
    next if $bin->{'filename'};
    my $location = $bin->{'location'};
    die("missing location for binary $bin->{'name'}\n") unless $location;
    die("bad location: $location\n") unless $location =~ /^(?:https?|zypp):\/\//;
    my $binname = calc_binname($bin);
    PBuild::Verify::verify_filename($binname);
    my $tmpname = ".$$.$binname";
    if ($bin->{'name'} =~ /^container:/) {
      # we cannot query containers, just download and set the filename
      die("container has no hdrmd5\n") unless $bin->{'hdrmd5'};
      download($location, "$repodir/$tmpname", "$repodir/$binname", "md5:$bin->{'hdrmd5'}", $ua);
      delete $bin->{'id'};
      $bin->{'filename'} = $binname;
      next;
    }
    download($location, "$repodir/$tmpname", undef, undef, $ua);
    fetchbinaries_replace($repodir, $tmpname, $binname, $bin);
  }
  # update _metadata
  PBuild::Util::store("$repodir/._metadata.$$", "$repodir/_metadata", $repo->{'bins'});
}

1;
