################################################################
#
# Copyright (c) 2017 SUSE Linux Products GmbH
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

package Build::Docker;

use Build::SimpleXML;	# to parse the annotation
use Build::SimpleJSON;

use strict;

sub unify {
  my %h = map {$_ => 1} @_;
  return grep(delete($h{$_}), @_);
}

sub gettargetarch {
  my ($config) = @_;
  my $arch = 'noarch';
  for (@{$config->{'macros'} || []}) {
    $arch = $1 if /^%define _target_cpu (\S+)/;
  }
  return $arch;
}

sub slurp {
  my ($fn) = @_;
  local *F;
  return undef unless open(F, '<', $fn);
  local $/ = undef;	# Perl slurp mode
  my $content = <F>;
  close F;
  return $content;
}

sub expandvar_cplx {
  my ($cplx, $vars) = @_;
  if ($cplx =~ /^\!([a-zA-Z0-9_]+)/) {
    return [] unless @{$vars->{$1} || []};
    my $n = $vars->{$1}->[0];
    return $vars->{$n} || [];
  }
  return [] unless $cplx =~ /^([^\}:]+):([-+])([^}]*)$/s;
  my ($n, $m, $v) = ($1, $2, $3);
  $v = expandvars($v, $vars) if $v =~ /\$/;
  my $o = join(' ', @{$vars->{$n} || []});
  return $o ne '' ? $vars->{$n} : [ $v ] if $m eq '-';
  return $o ne '' ? [ $v ] : [] if $m eq '+';
  return [];
}

sub expandvars {
  my ($str, $vars) = @_;
  $str =~ s/\$([a-zA-Z0-9_]+)|\$\{([^\}:\!]+)\}|\$\{([^}]+)\}/join(' ', @{$3 ? expandvar_cplx($3, $vars) : $vars->{$2 || $1} || []})/ge;
  return $str;
}

sub quote {
  my ($str, $q, $vars) = @_;
  $str = expandvars($str, $vars) if $vars && $q ne "'" && $str =~ /\$/;
  $str =~ s/([ \t\"\'\$\(\)])/sprintf("%%%02X", ord($1))/ge;
  return $str;
}

sub addrepo {
  my ($ret, $url, $prio) = @_;

  unshift @{$ret->{'imagerepos'}}, { 'url' => $url };
  $ret->{'imagerepos'}->[0]->{'priority'} = $prio if defined $prio;
  if (defined($Build::Kiwi::urlmapper) && !$Build::Kiwi::urlmapper) {
    unshift @{$ret->{'path'}}, { %{$ret->{'imagerepos'}->[0]} };
    return 1;
  }
  if ($Build::Kiwi::urlmapper) {
    my $prp = $Build::Kiwi::urlmapper->($url);
    if (!$prp) {
      $ret->{'error'} = "cannot map '$url' to obs";
      return undef;
    }
    my ($projid, $repoid) = split('/', $prp, 2);
    unshift @{$ret->{'path'}}, {'project' => $projid, 'repository' => $repoid};
    $ret->{'path'}->[0]->{'priority'} = $prio if defined $prio;
    return 1;
  } else {
    # this is just for testing purposes...
    $url =~ s/^\/+$//;
    $url =~ s/:\//:/g;
    my @url = split('/', $url);
    unshift @{$ret->{'path'}}, {'project' => $url[-2], 'repository' => $url[-1]} if @url >= 2;
    $ret->{'path'}->[0]->{'priority'} = $prio if defined $prio;
    return 1;
  }
}

sub cmd_zypper {
  my ($ret, @args) = @_;
  # skip global options
  while (@args && $args[0] =~ /^-/) {
    shift @args if $args[0] eq '-R' || $args[0] eq '--root' || $args[0] eq '--installroot';
    shift @args;
  }
  return unless @args;
  if ($args[0] eq 'in' || $args[0] eq 'install') {
    shift @args;
    while (@args && $args[0] =~ /^-/) {
      shift @args if $args[0] =~ /^--(?:from|repo|type)$/ || $args[0] =~ /^-[tr]$/;
      shift @args;
    }
    my @deps = grep {/^[a-zA-Z_0-9]/} @args;
    s/^([^<=>]+)([<=>]+)/$1 $2 / for @deps;
    push @{$ret->{'deps'}}, @deps;
  } elsif ($args[0] eq 'ar' || $args[0] eq 'addrepo') {
    my $prio;
    shift @args;
    while (@args && $args[0] =~ /^-/) {
      if ($args[0] eq '-p' || $args[0] eq '--priority') {
	$prio = 99 - $args[1];
	splice(@args, 0, 2);
	next;
      }
      shift @args if $args[0] =~ /^--(?:repo|type)$/ || $args[0] =~ /^-[rt]$/;
      shift @args;
    }
    if (@args) {
      my $path = $args[0];
      $path =~ s/\/[^\/]*\.repo$//;
      addrepo($ret, $path, $prio);
    }
  }
}

sub cmd_obs_pkg_mgr {
  my ($ret, @args) = @_;
  return unless @args;
  if ($args[0] eq 'add_repo') {
    shift @args;
    addrepo($ret, $args[0]) if @args;
  } elsif ($args[0] eq 'install') {
    shift @args;
    push @{$ret->{'deps'}}, @args;
  }
}

sub cmd_dnf {
  my ($ret, @args) = @_;
  # skip global options
  shift @args while @args && $args[0] =~ /^-/;
  return unless @args;
  if ($args[0] eq 'in' || $args[0] eq 'install') {
    shift @args;
    while (@args && $args[0] =~ /^-/) {
      shift @args;
    }
    push @{$ret->{'deps'}}, grep {/^[a-zA-Z_0-9]/} @args;
  }
}

sub cmd_apt_get {
  my ($ret, @args) = @_;
  shift @args while @args && $args[0] =~ /^-/;
  return unless @args;
  if ($args[0] eq 'install') {
    shift @args;
    push @{$ret->{'deps'}}, grep {/^[a-zA-Z_0-9]/} @args;
  }
}

sub cmd_apk {
  my ($ret, @args) = @_;
  shift @args while @args && $args[0] =~ /^-/;
  return unless @args;
  if ($args[0] eq 'add') {
    shift @args;
    push @{$ret->{'deps'}}, grep {/^[a-zA-Z_0-9]/} @args;
  }
}

sub cmd_curl {
  my ($ret, @args) = @_;
  my @urls;
  while (@args) {
    my $arg = shift @args;
    if ($arg eq '--url') {
      $arg = shift @args;
      push @urls, $arg if $arg =~ /^https?:\/\//;
    } elsif ($arg =~ /^-/) {
      shift @args if $arg eq '-d' || $arg =~ /^--data/ || $arg eq '-F' || $arg =~ /^--form/ || $arg eq '-m' || $arg =~ /^--max/ || $arg eq '-o' || $arg eq '--output' || $arg =~ /^--retry/ || $arg eq '-u' || $arg eq '--user' || $arg eq '-A' || $arg eq '--user-agent' || $arg eq '-H' || $arg eq '--header';
    } else {
      push @urls, $arg if $arg =~ /^https?:\/\//;
    }
  }
  for my $url (@urls) {
    my $asset = { 'url' => $url, 'type' => 'webcache' };
    push @{$ret->{'remoteassets'}}, $asset;
  }
}

sub cmd_wget {
  my ($ret, @args) = @_;
  my @urls;
  while (@args) {
    my $arg = shift @args;
    if ($arg =~ /^-/) {
      shift @args if $arg eq '-F' || $arg =~ /--post-data/ || $arg eq '-T' || $arg =~ /--timeout/ || $arg eq '-O' || $arg eq '--output-document' || $arg eq '-t' || $arg =~ /--tries/ || $arg eq '--user' || $arg eq '--password' || $arg eq '-U' || $arg eq '--user-agent' || $arg eq '--header';
    } else {
      push @urls, $arg if $arg =~ /^https?:\/\//;
    }
  }
  for my $url (@urls) {
    my $asset = { 'url' => $url, 'type' => 'webcache' };
    push @{$ret->{'remoteassets'}}, $asset;
  }
}

sub parse {
  my ($cf, $fn) = @_;

  my $unorderedrepos;
  my $plusrecommended;
  my $useobsrepositories;
  my $nosquash;
  my $dockerfile_data;
  if (ref($fn) eq 'SCALAR') {
    $dockerfile_data = $$fn;
  } else {
    $dockerfile_data = slurp($fn);
    return { 'error' => 'could not open Dockerfile' } unless defined $dockerfile_data;
  }
  my @lines = split(/\r?\n/, $dockerfile_data);

  my $ret = {
    'deps' => [],
    'path' => [],
    'imagerepos' => [],
  };

  my %build_vars;
  if ($cf->{'buildflags:dockerarg'}) {
    for (@{$cf->{'buildflags'} || []}) {
      $build_vars{$1} = [ $2 ] if /^dockerarg:(.*?)=(.*)$/s;
    }
  }

  my $excludedline;
  my $vars = {};
  my $vars_env = {};
  my $vars_meta = {};
  my %as_container;
  my $from_seen;

  my @requiredarch;
  my @badarch;
  my @containerrepos;
  my $basecontainer;

  while (@lines) {
    my $line = shift @lines;
    $line =~ s/^\s+//;
    if ($line =~ /^#/) {
      if ($line =~ /^#!BuildTag:\s*(.*?)$/) {
	my @tags = split(' ', $1);
	push @{$ret->{'containertags'}}, @tags if @tags;
      }
      if ($line =~ /^#!BuildName:\s*(\S+)\s*$/) {
	$ret->{'name'} = $1;
      }
      if ($line =~ /^#!BuildVersion:\s*(\S+)\s*$/) {
	$ret->{'version'} = $1;
      }
      if ($line =~ /^#!BuildRelease:\s*(\S+)\s*$/) {
	$ret->{'release'} = $1;
      }
      if ($line =~ /^#!BcntSyncTag:\s*(\S+)\s*$/) {
	$ret->{'bcntsynctag'} = $1;
      }
      if ($line =~ /^#!BuildConstraint:\s*(\S.+?)\s*$/) {
	push @{$ret->{'buildconstraint'}}, $1;
      }
      if ($line =~ /^#!UnorderedRepos\s*$/) {
        $unorderedrepos = 1;
      }
      if ($line =~ /^#!PlusRecommended\s*$/) {
        $plusrecommended = 1;
      }
      if ($line =~ /^#!UseOBSRepositories\s*$/) {
        $useobsrepositories = 1;
      }
      if ($line =~ /^#!NoSquash\s*$/) {
        $nosquash = 1;
      }
      if ($line =~ /^#!Milestone:\s*(\S+)\s*$/) {
	$ret->{'milestone'} = $1;
      }
      if ($line =~ /^#!ExcludeArch:\s*(.*?)$/) {
        push @badarch, split(' ', $1) ;
      }
      if ($line =~ /^#!ExclusiveArch:\s*(.*?)$/) {
        push @requiredarch, split(' ', $1) ;
      }
      if ($line =~ /^#!ArchExclusiveLine:\s*(.*?)$/) {
	my $arch = gettargetarch($cf);
	$excludedline = (grep {$_ eq $arch} split(' ', $1)) ? undef : 1;
      }
      if ($line =~ /^#!ArchExcludedLine:\s*(.*?)$/) {
	my $arch = gettargetarch($cf);
	$excludedline = (grep {$_ eq $arch} split(' ', $1)) ? 1 : undef;
      }
      if ($line =~ /^#!RemoteAsset(?:Url)?:\s*(.*?)\s*$/i) {
	my $remoteasset = {};
	for (split(' ', $1)) {
	  if (/\/\//) {
	    $remoteasset->{'url'} = $_;
	  } elsif (/^[a-z0-9]+:/) {
	    $remoteasset->{'digest'} = $_;
	  } elsif (/^[^\.\/][^\/]+$/s) {
	    $remoteasset->{'file'} = $_;
	  }
	}
        push @{$ret->{'remoteassets'}}, $remoteasset if %$remoteasset;
      }
      if ($line =~ /^#!ForceMultiVersion\s*$/) {
        $ret->{'multiversion'} = 1;
      }
      next;
    }
    # add continuation lines
    while (@lines && $line =~ s/\\[ \t]*$//) {
      shift @lines while @lines && $lines[0] =~ /^\s*#/;
      $line .= shift(@lines) if @lines;
    }
    $line =~ s/^\s+//;
    $line =~ s/\s+$//;
    next unless $line;
    if ($excludedline) {
      undef $excludedline;
      next;
    }
    my ($cmd, @args);
    ($cmd, $line) = split(' ', $line, 2);
    $cmd = uc($cmd);
    # escape and unquote
    $line =~ s/%/%25/g;
    $line =~ s/\\(.)/sprintf("%%%02X", ord($1))/ge;
    while ($line =~ /([\"\'])/) {
      my $q = $1;
      last unless $line =~ s/$q(.*?)$q/quote($1, $q, $vars)/e;
    }
    if ($cmd eq 'FROM') {
      $vars = { %$vars_meta };		# reset vars
    }
    # split into args then expand
    @args = split(/[ \t]+/, $line);
    for my $arg (@args) {
      $arg = expandvars($arg, $vars) if $arg =~ /\$/;
      $arg =~ s/%([a-fA-F0-9]{2})/chr(hex($1))/ge;
    }
    # process commands
    if ($cmd eq 'FROM') {
      shift @args if @args && $args[0] =~ /^--platform=/;
      $basecontainer = undef;
      if (@args && $as_container{$args[0]}) {
	$basecontainer = $as_container{$args[0]}->[1];
	$as_container{$args[2]} = [ $args[0], $basecontainer ] if @args > 2 && lc($args[1]) eq 'as';
      } elsif (@args && !$as_container{$args[0]}) {
        my $container = $args[0];
        if ($container ne 'scratch') {
	  if ($Build::Kiwi::urlmapper && $container =~ /^([^\/]+\.[^\/]+)\/[a-zA-Z0-9]/) {
	    my $prp = $Build::Kiwi::urlmapper->("registry://$1/");
	    push @containerrepos, $prp if $prp;
	  }
          $container .= ':latest' unless $container =~ /:[^:\/]+$/;
          $basecontainer = $container;
          $container = "container:$container";
          push @{$ret->{'deps'}}, $container unless grep {$_ eq $container} @{$ret->{'deps'}};
        }
	$as_container{$args[2]} = [ $args[0], $basecontainer ] if @args > 2 && lc($args[1]) eq 'as';
      }
      $vars_env = {};		# should take env from base container
      $vars = { %$vars_env };
      $from_seen = 1;
    } elsif ($cmd eq 'RUN') {
      $line =~ s/#.*//;	# get rid of comments
      for my $l (split(/(?:\||\|\||\&|\&\&|;|\)|\()/, $line)) {
	$l =~ s/^\s+//;
	$l =~ s/\s+$//;
	$l = expandvars($l, $vars) if $l =~ /\$/;
	@args = split(/[ \t]+/, $l);
	s/%([a-fA-F0-9]{2})/chr(hex($1))/ge for @args;
	next unless @args;
	my $rcmd = shift @args;
	$rcmd = shift @args if @args && ($rcmd eq 'then' || $rcmd eq 'else' || $rcmd eq 'elif' || $rcmd eq 'if' || $rcmd eq 'do');
	if ($rcmd eq 'zypper') {
	  cmd_zypper($ret, @args);
	} elsif ($rcmd eq 'yum' || $rcmd eq 'dnf') {
	  cmd_dnf($ret, @args);
	} elsif ($rcmd eq 'apt-get') {
	  cmd_apt_get($ret, @args);
	} elsif ($rcmd eq 'apk') {
	  cmd_apk($ret, @args);
	} elsif ($rcmd eq 'curl') {
	  cmd_curl($ret, @args);
	} elsif ($rcmd eq 'wget') {
	  cmd_wget($ret, @args);
	} elsif ($rcmd eq 'obs_pkg_mgr') {
	  cmd_obs_pkg_mgr($ret, @args);
	}
      }
    } elsif ($cmd eq 'ENV') {
      @args=("$args[0]=$args[1]") if @args == 2 && $args[0] !~ /=/;
      for (@args) {
        next unless /^(.*?)=(.*)$/;
	$vars->{$1} = [ $2 ];
	$vars_env->{$1} = [ $2 ];
      }
    } elsif ($cmd eq 'ARG') {
      for (@args) {
	next unless /^([^=]+)(?:=(.*))?$/;
	next if $vars_env->{$1};
	$vars->{$1} = $build_vars{$1} || (defined($2) ? [ $2 ] : $vars_meta->{$1} || []);
	$vars_meta->{$1} = $vars->{$1} unless $from_seen;
      }
    }
  }
  if ($basecontainer) {
    # always put the base container last
    my $container = "container:$basecontainer";
    @{$ret->{'deps'}} = grep {$_ ne $container} @{$ret->{'deps'}};
    push @{$ret->{'deps'}}, $container;
  }
  push @{$ret->{'deps'}}, '--dorecommends--', '--dosupplements--' if $plusrecommended;
  push @{$ret->{'deps'}}, '--unorderedimagerepos' if $unorderedrepos;
  my $version = $ret->{'version'};
  my $release = $ret->{'release'};
  $release = $cf->{'buildrelease'} if defined $cf->{'buildrelease'};
  for (@{$ret->{'containertags'} || []}) {
    s/<VERSION>/$version/g if defined $version;
    s/<RELEASE>/$release/g if defined $release;
  }
  $ret->{'name'} = 'docker' if !defined($ret->{'name'}) && !$cf->{'__dockernoname'};
  $ret->{'path'} = [ { 'project' => '_obsrepositories', 'repository' => '' } ] if $useobsrepositories;
  $ret->{'nosquash'} = 1 if $nosquash;
  $ret->{'basecontainer'} = $basecontainer if $basecontainer;
  $ret->{'exclarch'} = [ unify(@requiredarch) ] if @requiredarch;
  $ret->{'badarch'} = [ unify(@badarch) ] if @badarch;
  if (@containerrepos) {
    for (unify(@containerrepos)) {
      my @s = split('/', $_, 2);
      push @{$ret->{'containerpath'}}, {'project' => $s[0], 'repository' => $s[1] };
    }
  }
  return $ret;
}

sub showcontainerinfo {
  my ($disturl, $release, $annotationfile);
  while (@ARGV) {
    if (@ARGV > 2 && $ARGV[0] eq '--disturl') {
      (undef, $disturl) = splice(@ARGV, 0, 2);
    } elsif (@ARGV > 2 && $ARGV[0] eq '--release') {
      (undef, $release) = splice(@ARGV, 0, 2);
    } elsif (@ARGV > 2 && $ARGV[0] eq '--annotationfile') {
      (undef, $annotationfile) = splice(@ARGV, 0, 2);
    } else {
      last;
    }
  }
  my ($fn, $image, $taglist) = @ARGV;
  local $Build::Kiwi::urlmapper = sub { return $_[0] };
  my $cf = { '__dockernoname' => 1 };
  $cf->{'buildrelease'} = $release if defined $release;
  my $d = {};
  $d = parse($cf, $fn) if $fn;
  die("$d->{'error'}\n") if $d->{'error'};
  $image =~ s/.*\/// if defined $image;
  my @tags = split(' ', $taglist);
  for (@tags) {
    $_ .= ':latest' unless /:[^:\/]+$/;
    if (/:([0-9][^:]*)$/) {
      $d->{'version'} = $1 unless defined $d->{'version'};
    }
  }

  # parse annotation file
  my $annotation;
  if ($annotationfile) {
    $annotation = slurp($annotationfile);
    $annotation = $annotation ? Build::SimpleXML::parse($annotation) : undef;
    $annotation = $annotation && ref($annotation) eq 'HASH' ? $annotation->{'annotation'} : undef;
    $annotation = $annotation && ref($annotation) eq 'ARRAY' ? $annotation->[0] : undef;
    $annotation = undef unless ref($annotation) eq 'HASH';
  }

  my @repos = @{$d->{'imagerepos'} || []};
  # add repos from annotation
  if ($annotation) {
    my $annorepos = $annotation->{'repo'};
    $annorepos = undef unless $annorepos && ref($annorepos) eq 'ARRAY';
    for my $annorepo (@{$annorepos || []}) {
      next unless $annorepo && ref($annorepo) eq 'HASH' && $annorepo->{'url'};
      push @repos, { 'url' => $annorepo->{'url'}, '_type' => {'priority' => 'number'} };
      $repos[-1]->{'priority'} = $annorepo->{'priority'} if defined $annorepo->{'priority'};
    }
  }
  my $buildtime = time();
  my $containerinfo = {
    'buildtime' => $buildtime,
    '_type' => {'buildtime' => 'number'},
  };
  $containerinfo->{'tags'} = \@tags if @tags;
  $containerinfo->{'repos'} = \@repos if @repos;
  $containerinfo->{'file'} = $image if defined $image;
  $containerinfo->{'disturl'} = $disturl if defined $disturl;
  $containerinfo->{'name'} = $d->{'name'} if defined $d->{'name'};
  $containerinfo->{'version'} = $d->{'version'} if defined $d->{'version'};
  $containerinfo->{'release'} = $release if defined $release;
  $containerinfo->{'milestone'} = $d->{'milestone'} if defined $d->{'milestone'};
  if ($annotation && $d->{'basecontainer'}) {
    # XXX: verify that the annotation matches?
    for (qw{registry_refname registry_digest registry_fatdigest}) {
      next unless $annotation->{$_} && ref($annotation->{$_}) eq 'ARRAY';
      my $v = $annotation->{$_}->[0];
      $v = $v->{'_content'} if $v && ref($v) eq 'HASH';
      $containerinfo->{"base_$_"} = $v if $v;
    }
  }
  print Build::SimpleJSON::unparse($containerinfo)."\n";
}

sub show {
  my ($release);
  while (@ARGV) {
    if (@ARGV > 2 && $ARGV[0] eq '--release') {
      (undef, $release) = splice(@ARGV, 0, 2);
    } else {
      last;
    }
  }
  my ($fn, $field) = @ARGV;
  local $Build::Kiwi::urlmapper = sub { return $_[0] };
  my $cf = {};
  $cf->{'buildrelease'} = $release if defined $release;
  $cf->{'__dockernoname'} = 1 if $field && $field eq 'filename';
  my $d = {};
  $d = parse($cf, $fn) if $fn;
  die("$d->{'error'}\n") if $d->{'error'};
  $d->{'filename'} = "$d->{'name'}-$d->{'version'}" if !$d->{'filename'} && $d->{'name'} && $d->{'version'};
  my $x = $d->{$field};
  $x = [ $x ] unless ref $x;
  print "@$x\n";
}

1;
