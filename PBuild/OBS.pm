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

package PBuild::OBS;

use strict;

use PBuild::Util;
use PBuild::Download;
use PBuild::Cpio;
use PBuild::Structured;

my @binsufs = qw{rpm deb pkg.tar.gz pkg.tar.xz pkg.tar.zst};
my $binsufsre = join('|', map {"\Q$_\E"} @binsufs);

my @dtd_disableenable = (
     [[ 'disable' =>
        'arch',
        'repository',
     ]],
     [[ 'enable' =>
        'arch',
        'repository',
     ]],
);

my $dtd_repo = [
   'repository' => 
        'name',
        'rebuild',
        'block',
        'linkedbuild',
     [[ 'path' =>
            'project',
            'repository',
     ]],
      [ 'arch' ],
];


my $dtd_proj = [
    'project' =>
	'name',
	'kind',
	[],
     [[ 'link' =>
            'project',
            'vrevmode',
     ]],
      [ 'lock' => @dtd_disableenable ],
      [ 'build' => @dtd_disableenable ],
      [ 'publish' => @dtd_disableenable ],
      [ 'debuginfo' => @dtd_disableenable ],
      [ 'useforbuild' => @dtd_disableenable ],
      [ 'binarydownload' => @dtd_disableenable ],
      [ 'sourceaccess' => @dtd_disableenable ],
      [ 'access' => @dtd_disableenable ],
      [ $dtd_repo ],
];

#
# get the project data from an OBS project
#
sub fetch_proj {
  my ($projid, $baseurl) = @_;
  my $projid2 = PBuild::Util::urlencode($projid);
  my ($projxml) = PBuild::Download::fetch("${baseurl}source/$projid2/_meta");
  return PBuild::Structured::fromxml($projxml, $dtd_proj, 0, 1);
}

#
# get the config from an OBS project
#
sub fetch_config {
  my ($prp, $baseurl) = @_;
  my ($projid, $repoid) = split('/', $prp, 2);
  my $projid2 = PBuild::Util::urlencode($projid);
  my ($config) = PBuild::Download::fetch("${baseurl}source/$projid2/_config", 'missingok' => 1);
  $config = '' unless defined $config;
  $config = "\n### from $projid\n%define _repository $repoid\n$config" if $config;
  return $config;
}

#
# expand the path for an OBS project/repository
#
sub expand_path {
  my ($prp, $baseurl) = @_;
  my %done;
  my @ret;
  my @path = ($prp);
  while (@path) {
    my $t = shift @path;
    push @ret, $t unless $done{$t};
    $done{$prp} = 1;
    if (!@path) {
      last if $done{"/$t"};
      my ($tprojid, $trepoid) = split('/', $t, 2);
      my $proj = fetch_proj($tprojid, $baseurl);
      $done{"/$t"} = 1;
      my $repo = (grep {$_->{'name'} eq $trepoid} @{$proj->{'repository'} || []})[0];
      next unless $repo;
      for (@{$repo->{'path'} || []}) {
        push @path, "$_->{'project'}/$_->{'repository'}";
      }
    }
  }
  return @ret;
}

#
# get the configs/repo urls for an OBS project/repository
# expand the path if $islast is true
#
sub fetch_all_configs {
  my ($url, $opts, $islast) = @_;
  die("bad obs: reference\n") unless $url =~ /^obs:\/{1,3}([^\/]+\/[^\/]+)\/?$/;
  my $prp = PBuild::Util::urldecode($1);
  die("please specify the build service url with the --obs option\n") unless $opts->{'obs'};
  my $baseurl = $opts->{'obs'};
  $baseurl .= '/' unless $baseurl =~ /\/$/;

  my @prps;
  if ($islast) {
    @prps = expand_path($prp, $baseurl);
  } else {
    @prps = ($prp);
  }
  my @configs;
  for my $xprp (@prps) {
    my $config = fetch_config($xprp, $baseurl);
    push @configs, $config if $config;
  }
  my @repourls;
  push @repourls, "obs:\/".PBuild::Util::urlencode($_) for @prps;
  return (\@configs, \@repourls);
}

#
# parse a dependency in libsolv's testcase style
#
my %testcaseops  = (  
  '&'       => 1,
  '|'       => 2,
  '<IF>'    => 3,
  '<UNLESS' => 4,
  '<ELSE>'  => 5,
  '+'       => 6,
  '-'       => 7,
);

sub parse_testcasedep_rec {
  my ($dep, $chainop) = @_;
  no warnings 'recursion';
  my $d = $dep;
  $chainop ||= 0;
  my ($r, $r2);
  $d =~ s/^\s+//;
  if ($d =~ s/^\(//) {
    ($d, $r) = parse_testcasedep_rec($d);
    return ($d, undef) unless $r && $d =~ s/\s*^\)//;
  } else {
    return ($d, undef) if $d eq '' || $d =~ /^\)/;
    return ($d, undef) unless $d =~ s/([^\s\)]+)//;
    $r = $1;
    $r = "$r$1" if $d =~ s/^( (?:<|<=|>|>=|<=>|=) [^\s\)]+)//;
    $r =~ s/\\([A-Fa-f2-9][A-Fa-f0-9])/chr(hex($1))/sge;
    $r = [0, $r];
  }
  $d =~ s/^\s+//;
  return ($d, $r) if $d eq '' || $d =~ /^\)/;
  return ($d, undef) unless $d =~ s/([^\s\)]+)//;
  my $op = $testcaseops{$1};
  return ($d, undef) unless $op; 
  return ($d, undef) if $op == 5 && $chainop != 3 && $chainop != 4;
  $chainop = 0 if $op == 5;
  return ($d, undef) if $chainop && (($chainop != 1 && $chainop != 2 && $chainop != 6) || $op != $chainop);
  ($d, $r2) = parse_testcasedep_rec($d, $op);
  return ($d, undef) unless $r2; 
  if (($op == 3 || $op == 4) && $r2->[0] == 5) { 
    $r = [$op, $r, $r2->[1], $r2->[2]];
  } else {
    $r = [$op, $r, $r2];
  }
  return ($d, $r); 
}

#
# convert a parsed dependency to rpm's rich dep style
#
my @rpmops = ('', 'and', 'or', 'if', 'unless', 'else', 'with', 'without');

sub rpmdepformat_rec {
  my ($r, $addparens) = @_;
  no warnings 'recursion';
  my $op = $r->[0];
  return $r->[1] unless $op;
  my $top = $rpmops[$op];
  my $r1 = rpmdepformat_rec($r->[1], 1);
  if (($op == 3 || $op == 4) && @$r == 4) {
    $r1 = "$r1 $top " . rpmdepformat_rec($r->[2], 1);
    $top = 'else';
  }
  my $addparens2 = 1;
  $addparens2 = 0 if $r->[2]->[0] == $op && ($op == 1 || $op == 2 || $op == 6);
  my $r2 = rpmdepformat_rec($r->[-1], $addparens2);
  return $addparens ? "($r1 $top $r2)" : "$r1 $top $r2";
}

#
# recode the dependencies in a binary from testcaseformat to native
#
sub recode_deps {
  my ($b) = @_;
  for my $dep (@{$b->{'requires'} || []}, @{$b->{'conflicts'} || []}, @{$b->{'recommends'} || []}, @{$b->{'supplements'} || []}) {
    next unless $dep =~ / (?:<[A-Z]|[\-\+\|\&\.])/;
    my ($d, $r) = parse_testcasedep_rec($dep);
    next if !$r || $d ne '';
    $dep = rpmdepformat_rec($r, 1);	# currently only rpm supported
  }
}

#
# Extract a binary from the cpio archive downloaded by fetchbinaries
#
sub fetch_binaries_cpioextract {
  my ($ent, $xfile, $repodir, $names, $callback) = @_;
  return undef unless $ent->{'cpiotype'} == 8;
  my $name = $ent->{'name'};
  if (!defined($xfile)) {
    return undef unless $name =~ s/\.($binsufsre)$//;
    my $suf = $1;
    return undef unless $names->{$name};
    my $tmpname = $names->{$name}->[0];
    return undef unless $tmpname =~ /\.\Q$suf\E$/;
    return "$repodir/$tmpname";	# ok, extract this one!
  }
  die unless $name =~ s/\.($binsufsre)$//;
  die unless $names->{$name};
  $callback->($repodir, @{$names->{$name}});
  return undef;	# continue extracting
}

#
# Download binaries in batches from a remote obs instance
#
sub fetch_binaries {
  my ($url, $repodir, $names, $callback, $ua) = @_;
  my @names = sort keys %$names;
  while (@names) {
    $ua ||= PBuild::Download::create_ua();
    my @nchunk = splice(@names, 0, 100);
    my $chunkurl = "$url/_repository?view=cpio";
    $chunkurl .= "&binary=".PBuild::Util::urlencode($_) for @nchunk;
    my $tmpcpio = "$repodir/.$$.binaries.cpio";
    PBuild::Download::download($chunkurl, $tmpcpio, undef, 'ua' => $ua, 'retry' => 3);
    PBuild::Cpio::cpio_extract($tmpcpio, sub {fetch_binaries_cpioextract($_[0], $_[1], $repodir, $names, $callback)});
    unlink($tmpcpio);
  }
}

#
# Get the repository metadata for an OBS repo
#
sub fetch_repodata {
  my ($url, $tmpdir, $arch, $opts, $modules) = @_;
  die("bad obs: reference\n") unless $url =~ /^obs:\/{1,3}([^\/]+\/[^\/]+)(?:\/([^\/]*))?$/;
  my $prp = $1;
  $arch = $2 if $2;
  die("please specify the build service url with the --obs option\n") unless $opts->{'obs'};
  my $baseurl = $opts->{'obs'};
  $baseurl .= '/' unless $baseurl =~ /\/$/;
  my $requrl .= "${baseurl}build/$prp/$arch/_repository?view=cache";
  $requrl .= "&module=".PBuild::Util::urlencode($_) for @{$modules || []};
  PBuild::Download::download($requrl, "$tmpdir/repository.cpio", undef, 'retry' => 3);
  PBuild::Cpio::cpio_extract("$tmpdir/repository.cpio", "$tmpdir/repository.data", 'extract' => 'repositorycache');
  my $rdata = PBuild::Util::retrieve("$tmpdir/repository.data");
  my @bins = grep {ref($_) eq 'HASH' && defined($_->{'name'})} values %{$rdata || {}};
  for (@bins) {
    if ($_->{'path'} =~ /^\.\.\/([^\/\.][^\/]*\/[^\/\.][^\/]*)$/s) {
      $_->{'location'} = "${baseurl}build/$prp/$arch/$1";  # obsbinlink to package
    } else {
      $_->{'location'} = "${baseurl}build/$prp/$arch/_repository/$_->{'path'}";
    }
    recode_deps($_);       # recode deps from testcase format to rpm
  }
  return \@bins;
}

1;
