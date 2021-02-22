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

use PBuild::Download;
use PBuild::Structured;

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
  $projid =~ s/([\000-\040<>;\"#\?&\+=%[\177-\377])/sprintf("%%%02X",ord($1))/sge;
  my ($projxml) = PBuild::Download::fetch("${baseurl}source/$projid/_meta");
  return PBuild::Structured::fromxml($projxml, $dtd_proj, 0, 1);
}

#
# get the config from an OBS project
#
sub fetch_config {
  my ($prp, $baseurl) = @_;
  my ($projid, $repoid) = split('/', $prp, 2);
  my $projid2 = $projid;
  $projid2 =~ s/([\000-\040<>;\"#\?&\+=%[\177-\377])/sprintf("%%%02X",ord($1))/sge;
  my ($config) = PBuild::Download::fetch("${baseurl}source/$projid2/_config", 'missingok' => 1);
  $config = '' unless defined $config;
  $config .= "\n### from $projid\n%define _repository $repoid\n$config" if $config;
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
  my $prp = $1;
  die("please specify the build service url with the --obs option\n") unless $opts->{'obs'};
  my $baseurl = $opts->{'obs'};
  $baseurl .= '/' unless $baseurl =~ /\/$/;

  $prp =~ s/%([a-fA-F0-9]{2})/chr(hex($1))/sge;
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
  for my $xprp (@prps) {
    my $xprp2 = $xprp;
    $xprp2 =~ s/([\000-\040<>;\"#\?&\+=%[\177-\377])/sprintf("%%%02X",ord($1))/sge;
    push @repourls, "obs:\/$xprp2";
  }
  return (\@configs, \@repourls);
}

#
# recode the dependencies in a binary from testcaseformat to native
#
sub recode_deps {
  my ($b) = @_;
  for my $d (@{$b->{'requires'} || []}, @{$b->{'conflicts'} || []}, @{$b->{'recommends'} || []}, @{$b->{'supplements'} || []}) {
  }
}

1;
