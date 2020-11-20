################################################################
#
# Copyright (c) 1995-2014 SUSE Linux Products GmbH
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

package Build::Kiwi;

use strict;
use Build::SimpleXML;
use Build::SimpleJSON;

our $bootcallback;
our $urlmapper;
our $repoextras = 0;	# priority, flags, ...

sub unify {
  my %h = map {$_ => 1} @_;
  return grep(delete($h{$_}), @_);
}

sub expandFallBackArchs {
  my ($fallbackArchXML, @archs) = @_;
  my %fallbacks;
  for (@{$fallbackArchXML->{'arch'} || []}) {
    $fallbacks{$_->{'id'}} = $_->{'fallback'} if $_->{id} && $_->{'fallback'};
  }
  my @out;
  while (@archs) {
    push @out, shift @archs;
    push @archs, delete $fallbacks{$out[-1]} if $fallbacks{$out[-1]};
  }
  return unify(@out);
}

# sles10 perl does not have the version.pm
# implement own hack
sub versionstring {
  my ($str) = @_; 
  my $result = 0;
  $result = $result * 100 + $_ for split (/\./, $str, 2);
  return $result;
}

my $schemaversion56 = versionstring('5.6');

sub kiwiparse_product {
  my ($kiwi, $xml, $arch, $buildflavor) = @_;

  my $ret = {};
  my @repos;
  my %repoprio;		# XXX: unused
  my @packages;
  my @requiredarch;
  my @badarch;
  my $obsexclusivearch;
  my $obsexcludearch;
  $obsexclusivearch = $1 if $xml =~ /^\s*<!--\s+OBS-ExclusiveArch:\s+(.*)\s+-->\s*$/im;
  $obsexcludearch = $1 if $xml =~ /^\s*<!--\s+OBS-ExcludeArch:\s+(.*)\s+-->\s*$/im;
  $ret->{'milestone'} = $1 if $xml =~ /^\s*<!--\s+OBS-Milestone:\s+(.*)\s+-->\s*$/im;

  $ret->{'name'} = $kiwi->{'name'} if $kiwi->{'name'};
  $ret->{'filename'} = $kiwi->{'name'} if $kiwi->{'name'};
  my $description = (($kiwi->{'description'} || [])->[0]) || {};
  if (!$ret->{'name'} && $description->{'specification'}) {
    $ret->{'name'} = $description->{'specification'}->[0]->{'_content'};
  }

  # parse the preferences section
  my $preferences = $kiwi->{'preferences'} || [];
  die("products must have exactly one preferences element\n") unless @$preferences == 1;
  # take default version setting
  if ($preferences->[0]->{'version'}) {
    $ret->{'version'} = $preferences->[0]->{'version'}->[0]->{'_content'};
  }
  die("products must have exactly one type element in the preferences\n") unless @{$preferences->[0]->{'type'} || []} == 1;
  my $preftype = $preferences->[0]->{'type'}->[0];
  if (defined $preftype->{'image'}) {
    # for kiwi 4.1 and 5.x
    die("products must use type 'product'\n") unless $preftype->{'image'} eq 'product';
  } else {
    # for kiwi 3.8 and before
    die("products must use type 'product'\n") unless $preftype->{'_content'} eq 'product';
  }
  push @packages, "kiwi-filesystem:$preftype->{'filesystem'}" if $preftype->{'filesystem'};
  die("boot type not supported in products\n") if defined $preftype->{'boot'};

  my $instsource = ($kiwi->{'instsource'} || [])->[0];
  die("products must have an instsource element\n") unless $instsource;

  # get repositories
  for my $repository (sort {$a->{priority} <=> $b->{priority}} @{$instsource->{'instrepo'} || []}) {
    my $kiwisource = ($repository->{'source'} || [])->[0];
    if ($kiwisource->{'path'} eq 'obsrepositories:/') {
      push @repos, '_obsrepositories/';		# special case, OBS will expand it.
    } elsif ($kiwisource->{'path'} =~ /^obs:\/\/\/?([^\/]+)\/([^\/]+)\/?$/) {
      push @repos, "$1/$2";
    } else {
      my $prp;
      $prp = $urlmapper->($kiwisource->{'path'}) if $urlmapper;
      die("instsource repo url not using obs:/ scheme: $kiwisource->{'path'}\n") unless $prp;
      push @repos, $prp;
    }
  }

  $ret->{'sourcemedium'} = -1;
  $ret->{'debugmedium'} = -1;
  if ($instsource->{'productoptions'}) {
    my $productoptions = $instsource->{'productoptions'}->[0] || {};
    for my $po (@{$productoptions->{'productvar'} || []}) {
      $ret->{'drop_repository'} = $po->{'_content'} if $po->{'name'} eq 'DROP_REPOSITORY';
      $ret->{'version'} = $po->{'_content'} if $po->{'name'} eq 'VERSION';
    }
    for my $po (@{$productoptions->{'productoption'} || []}) {
      $ret->{'sourcemedium'} = $po->{'_content'} if $po->{'name'} eq 'SOURCEMEDIUM';
      $ret->{'debugmedium'} = $po->{'_content'} if $po->{'name'} eq 'DEBUGMEDIUM';
      $ret->{'milestone'} = $po->{'_content'} if $po->{'name'} eq 'BETA_VERSION';
    }
  }
  if ($instsource->{'architectures'}) {
    my $architectures = $instsource->{'architectures'}->[0] || {};
    for my $ra (@{$architectures->{'requiredarch'} || []}) {
      push @requiredarch, $ra->{'ref'} if defined $ra->{'ref'};
    }
  }

  # Find packages and possible additional required architectures
  my @additionalarchs;
  my @pkgs;
  push @pkgs, @{$instsource->{'metadata'}->[0]->{'repopackage'} || []} if $instsource->{'metadata'};
  push @pkgs, @{$instsource->{'repopackages'}->[0]->{'repopackage'} || []} if $instsource->{'repopackages'};
  @pkgs = unify(@pkgs);
  for my $package (@pkgs) {
    # filter packages, which are not targeted for the wanted plattform
    if ($package->{'arch'}) {
      my $valid;
      for my $ma (@requiredarch) {
        for my $pa (split(',', $package->{'arch'})) {
          $valid = 1 if $ma eq $pa;
        }
      }
      next unless $valid;
    }

    # not nice, but optimizes our build dependencies
    # FIXME: design a real blacklist option in kiwi
    if ($package->{'onlyarch'} && $package->{'onlyarch'} eq 'skipit') {
      push @packages, "-$package->{'name'}";
      next;
    }
    push @packages, "-$package->{'replaces'}" if $package->{'replaces'};

    # we need this package
    push @packages, $package->{'name'};

    # find the maximal superset of possible required architectures
    push @additionalarchs, split(',', $package->{'addarch'}) if $package->{'addarch'};
    push @additionalarchs, split(',', $package->{'onlyarch'}) if $package->{'onlyarch'};
  }
  @requiredarch = unify(@requiredarch, @additionalarchs);

  #### FIXME: kiwi files have no informations where to get -32bit packages from
  push @requiredarch, "i586" if grep {/^ia64/} @requiredarch;
  push @requiredarch, "i586" if grep {/^x86_64/} @requiredarch;
  push @requiredarch, "ppc" if grep {/^ppc64/} @requiredarch;
  push @requiredarch, "s390" if grep {/^s390x/} @requiredarch;
  
  @requiredarch = expandFallBackArchs($instsource->{'architectures'}->[0], @requiredarch);

  push @packages, "kiwi-packagemanager:instsource";

  push @requiredarch, split(' ', $obsexclusivearch) if $obsexclusivearch;
  push @badarch , split(' ', $obsexcludearch) if $obsexcludearch;

  $ret->{'exclarch'} = [ unify(@requiredarch) ] if @requiredarch;
  $ret->{'badarch'} = [ unify(@badarch) ] if @badarch;
  $ret->{'deps'} = [ unify(@packages) ];
  $ret->{'path'} = [ unify(@repos) ];
  $ret->{'imagetype'} = [ 'product' ];
  for (@{$ret->{'path'} || []}) {
    my @s = split('/', $_, 2);
    $_ = {'project' => $s[0], 'repository' => $s[1]};
    $_->{'priority'} = $repoprio{"$s[0]/$s[1]"} if $repoextras && defined $repoprio{"$s[0]/$s[1]"};
  }
  return $ret;
}

sub kiwiparse {
  my ($xml, $arch, $buildflavor, $release, $count) = @_;
  $count ||= 0;
  die("kiwi config inclusion depth limit reached\n") if $count++ > 10;

  my $kiwi = Build::SimpleXML::parse($xml);
  die("not a kiwi config\n") unless $kiwi && $kiwi->{'image'};
  $kiwi = $kiwi->{'image'}->[0];

  # check if this is a product, we currently test for the 'instsource' element
  return kiwiparse_product($kiwi, $xml, $arch, $buildflavor) if $kiwi->{'instsource'};

  my $ret = {};
  my @types;
  my @repos;
  my @imagerepos;
  my @bootrepos;
  my @containerrepos;
  my @packages;
  my @extrasources;
  my $obsexclusivearch;
  my $obsexcludearch;
  my $obsprofiles;
  my $unorderedrepos;
  my @ignorepackages;
  $obsexclusivearch = $1 if $xml =~ /^\s*<!--\s+OBS-ExclusiveArch:\s+(.*)\s+-->\s*$/im;
  $obsexcludearch = $1 if $xml =~ /^\s*<!--\s+OBS-ExcludeArch:\s+(.*)\s+-->\s*$/im;
  $obsprofiles = $1 if $xml =~ /^\s*<!--\s+OBS-Profiles:\s+(.*)\s+-->\s*$/im;
  $ret->{'milestone'} = $1 if $xml =~ /^\s*<!--\s+OBS-Milestone:\s+(.*)\s+-->\s*$/im;
  if ($obsprofiles) {
    $obsprofiles = [ grep {defined($_)} map {$_ eq '@BUILD_FLAVOR@' ? $buildflavor : $_} split(' ', $obsprofiles) ];
  }
  $unorderedrepos = 1 if $xml =~ /^\s*<!--\s+OBS-UnorderedRepos\s+-->\s*$/im;
  for ($xml =~ /^\s*<!--\s+OBS-Imagerepo:\s+(.*)\s+-->\s*$/img) {
    push @imagerepos, { 'url' => $_ };
  }
  for ($xml =~ /^\s*<!--\s+OBS-IgnorePackage:\s+(.*)\s+-->\s*$/img) {
    push @ignorepackages, split(' ', $_);
  }

  my $schemaversion = $kiwi->{'schemaversion'} ? versionstring($kiwi->{'schemaversion'}) : 0;
  $ret->{'name'} = $kiwi->{'name'} if $kiwi->{'name'};
  $ret->{'filename'} = $kiwi->{'name'} if $kiwi->{'name'};
  my $description = (($kiwi->{'description'} || [])->[0]) || {};
  if (!$ret->{'name'} && $description->{'specification'}) {
    $ret->{'name'} = $description->{'specification'}->[0]->{'_content'};
  }

  # usedprofiles also include direct wanted profile targets and indirect required profiles
  my %usedprofiles;
  # obsprofiles arch filtering
  if ($obsprofiles && $arch && $kiwi->{'profiles'} && $kiwi->{'profiles'}->[0]->{'profile'}) {
    # reduce set of profiles to the ones matching our architecture
    my @validprofiles;
    for my $prof (@{$kiwi->{'profiles'}[0]->{'profile'}}) {
      next unless $prof->{'name'};
      if (!$prof->{'arch'}) {
	push @validprofiles, $prof;
      } else {
	my $ma = $arch;
	$ma =~ s/i[456]86/i386/;
	for my $pa (split(",", $prof->{'arch'})) {
	  $pa =~ s/i[456]86/i386/;
	  next unless $ma eq $pa;
	  push @validprofiles, $prof;
	  last;
	}
      }
    }
    my %validprofiles = map {$_->{'name'} => 1} @validprofiles;
    $obsprofiles = [ grep {$validprofiles{$_}} @$obsprofiles ];
    my %obsprofiles = map {$_ => 1} @$obsprofiles;
    my @todo = grep {$obsprofiles{$_->{'name'}}} @validprofiles;
    while (@todo) {
      my $prof = shift @todo;
      next if $usedprofiles{$prof->{'name'}};	# already done
      $usedprofiles{$prof->{'name'}} = 1;
      for my $req (@{$prof->{'requires'} || []}) {
	push @todo, grep {$_->{'name'} eq $req->{'profile'}} @validprofiles;
      }
    }
  }

  # take default version setting
  my $preferences = ($kiwi->{'preferences'} || []);
  if ($preferences->[0]->{'version'}) {
    $ret->{'version'} = $preferences->[0]->{'version'}->[0]->{'_content'};
  }

  # add extra tags
  my @extratags;
  if ($xml =~ /^\s*<!--\s+OBS-AddTag:\s+(.*)\s+-->\s*$/im) {
    for (split(' ', $1)) {
      s/<VERSION>/$ret->{'version'}/g if $ret->{'version'};
      s/<RELEASE>/$release/g if $release;
      $_ = "$_:latest" unless /:[^\/]+$/;
      push @extratags, $_;
    }
  }

  my $containerconfig;
  for my $pref (@{$preferences || []}) {
    if ($obsprofiles && $pref->{'profiles'}) {
      next unless grep {$usedprofiles{$_}} split(",", $pref->{'profiles'});
    }
    for my $type (@{$pref->{'type'} || []}) {
      next unless @{$pref->{'type'}} == 1 || !$type->{'optional'};
      if (defined $type->{'image'}) {
        # for kiwi 4.1 and 5.x
        push @types, $type->{'image'};
        push @packages, "kiwi-image:$type->{'image'}" if $schemaversion >= $schemaversion56;
      } else {
        # for kiwi 3.8 and before
        push @types, $type->{'_content'};
      }
      # save containerconfig so that we can retrieve the tag
      $containerconfig = $type->{'containerconfig'}->[0] if $type->{'containerconfig'};

      # add derived container dependency
      if ($type->{'derived_from'}) {
	my $derived = $type->{'derived_from'};
	my ($name, $prp);
	if ($derived =~ /^obs:\/{1,3}([^\/]+)\/([^\/]+)\/(.*?)(?:#([^\#\/]+))?$/) {
	  $name = defined($4) ? "$3:$4" : "$3:latest";
	  $prp = "$1/$2";
	} elsif ($derived =~ /^obsrepositories:\/{1,3}([^\/].*?)(?:#([^\#\/]+))?$/) {
	  $name = defined($2) ? "$1:$2" : "$1:latest";
	} elsif ($derived =~ /^file:/) {
	  next;		# just ignore and hope
	} elsif ($derived =~ /^(.*)\/([^\/]+?)(?:#([^\#\/]+))?$/) {
	  my $url = $1;
	  $name = defined($3) ? "$2:$3" : "$2:latest";
	  $prp = $urlmapper->($url) if $urlmapper;
	  # try again with one element moved from url to name
	  if (!$prp && $derived =~ /^(.*)\/([^\/]+\/[^\/]+?)(?:#([^\#\/]+))?$/) {
	    $url = $1;
	    $name = defined($3) ? "$2:$3" : "$2:latest";
	    $prp = $urlmapper->($url) if $urlmapper;
	  }
	  undef $name unless $prp;
	}
	die("derived_from url not using obs:/ scheme: $derived\n") unless defined $name;
	push @packages, "container:$name";
	push @containerrepos, $prp if $prp;
      }

      push @packages, "kiwi-filesystem:$type->{'filesystem'}" if $type->{'filesystem'};
      if (defined $type->{'boot'}) {
        if ($type->{'boot'} =~ /^obs:\/\/\/?([^\/]+)\/([^\/]+)\/?$/) {
          next unless $bootcallback;
          my ($bootxml, $xsrc) = $bootcallback->($1, $2);
          next unless $bootxml;
          push @extrasources, $xsrc if $xsrc;
          my $bret = kiwiparse($bootxml, $arch, $buildflavor, $release, $count);
          push @bootrepos, map {"$_->{'project'}/$_->{'repository'}"} @{$bret->{'path'} || []};
          push @packages, @{$bret->{'deps'} || []};
          push @extrasources, @{$bret->{'extrasource'} || []};
        } else {
          die("bad boot reference: $type->{'boot'}\n") unless $type->{'boot'} =~ /^([^\/]+)\/([^\/]+)$/;
          push @packages, "kiwi-boot:$1";
        }
      }
    }
  }

  die("image contains 'product' type\n") if grep {$_ eq 'product'} @types;

  my $packman = $preferences->[0]->{'packagemanager'}->[0]->{'_content'} || '';

  # calculate priority for sorting
  for (@{$kiwi->{'repository'} || []}) {
    $_->{'sortprio'} = 0;
    if (defined($_->{'priority'})) {
      $_->{'sortprio'} = $packman eq 'smart' ? $_->{'priority'} : 99 - $_->{'priority'};
    }
  }

  my @repositories = sort {$b->{'sortprio'} <=> $a->{'sortprio'}} @{$kiwi->{'repository'} || []};

  my %repoprio;
  for my $repository (@repositories) {
    my $kiwisource = ($repository->{'source'} || [])->[0];
    next unless $kiwisource;	# huh?
    next if $kiwisource->{'path'} eq '/var/lib/empty';	# grr
    if ($repository->{'imageonly'} || $repository->{'imageinclude'}) {
      # this repo will be configured in the image. Save so that we can write it into the containerinfo
      my $imagerepo = { 'url' => $kiwisource->{'path'} };
      $imagerepo->{'priority'} = $repository->{'sortprio'} if defined $repository->{'priority'};
      push @imagerepos, $imagerepo;
    }
    next if $repository->{'imageonly'};
    my $prp;
    if ($kiwisource->{'path'} eq 'obsrepositories:/') {
      $prp = '_obsrepositories/';
    } elsif ($kiwisource->{'path'} =~ /^obs:\/{1,3}([^\/]+)\/([^\/]+)\/?$/) {
      $prp = "$1/$2";
    } else {
      $prp = $urlmapper->($kiwisource->{'path'}) if $urlmapper;
      die("repo url not using obs:/ scheme: $kiwisource->{'path'}\n") unless $prp;
    }
    push @repos, $prp;
    $repoprio{$prp} = $repository->{'sortprio'} if defined $repository->{'priority'};
  }

  # Find packages for the image
  my @pkgs;
  my $patterntype;
  for my $packages (@{$kiwi->{'packages'}}) {
    next if $packages->{'type'} && $packages->{'type'} ne 'image' && $packages->{'type'} ne 'bootstrap';
    # we could skip the sections also when no profile is used,
    # but don't to stay backward compatible
    if ($obsprofiles && $packages->{'profiles'}) {
      my @section_profiles = split(",", $packages->{'profiles'});

      next unless grep {$usedprofiles{$_}} @section_profiles;
    }

    $patterntype ||= $packages->{'patternType'};
    push @pkgs, @{$packages->{'package'}} if $packages->{'package'};
    for my $pattern (@{$packages->{'namedCollection'} || []}) {
      push @pkgs, { %$pattern, 'name' => "pattern() = $pattern->{'name'}" } if $pattern->{'name'};
    }
    for my $product (@{$packages->{'product'} || []}) {
      push @pkgs, { %$product, 'name' => "product() = $product->{'name'}" } if $product->{'name'};
    }
    for my $pattern (@{$packages->{'opensusePatterns'} || []}) {
      push @pkgs, { %$pattern, 'name' => "pattern() = $pattern->{'name'}" } if $pattern->{'name'};
    }
    for my $product (@{$packages->{'opensuseProduct'} || []}) {
      push @pkgs, { %$product, 'name' => "product() = $product->{'name'}" } if $product->{'name'};
    }
  }
  $patterntype ||= 'onlyRequired';
  @pkgs = unify(@pkgs);
  for my $package (@pkgs) {
    # filter packages which are not targeted for the wanted plattform
    if ($package->{'arch'}) {
      my $valid;
      my $ma = $arch;
      $ma =~ s/i[456]86/i386/;
      for my $pa (split(",", $package->{'arch'})) {
        $pa =~ s/i[456]86/i386/;
        $valid = 1 if $ma eq $pa;
      }
      next unless $valid;
    }
    # handle replaces as buildignore
    push @packages, "-$package->{'replaces'}" if $package->{'replaces'};

    # we need this package
    push @packages, $package->{'name'};
  }
  push @packages, map {"-$_"} @ignorepackages;
  push @packages, "kiwi-packagemanager:$packman" if $packman;
  push @packages, "--dorecommends--", "--dosupplements--" if $patterntype && $patterntype eq 'plusRecommended';
  push @packages, '--unorderedimagerepos', if $unorderedrepos;

  $ret->{'exclarch'} = [ unify(split(' ', $obsexclusivearch)) ] if $obsexclusivearch;
  $ret->{'badarch'} = [ unify(split(' ', $obsexcludearch)) ] if $obsexcludearch;
  $ret->{'deps'} = [ unify(@packages) ];
  $ret->{'path'} = [ unify(@repos, @bootrepos) ];
  $ret->{'containerpath'} = [ unify(@containerrepos) ] if @containerrepos;
  $ret->{'imagetype'} = [ unify(@types) ];
  $ret->{'extrasource'} = \@extrasources if @extrasources;
  for (@{$ret->{'path'} || []}) {
    my @s = split('/', $_, 2);
    $_ = {'project' => $s[0], 'repository' => $s[1]};
    $_->{'priority'} = $repoprio{"$s[0]/$s[1]"} if $repoextras && defined $repoprio{"$s[0]/$s[1]"};
  }
  for (@{$ret->{'containerpath'} || []}) {
    my @s = split('/', $_, 2);
    $_ = {'project' => $s[0], 'repository' => $s[1]};
  }
  $ret->{'imagerepos'} = \@imagerepos if @imagerepos;
  if ($containerconfig) {
    my $containername = $containerconfig->{'name'};
    my @containertags;
    if (defined $containername) {
      push @containertags, $containerconfig->{'tag'} if defined $containerconfig->{'tag'};
      push @containertags, 'latest' unless @containertags;
      if (defined($containerconfig->{'additionaltags'})) {
	push @containertags, split(',', $containerconfig->{'additionaltags'});
      }
      @containertags = map {"$containername:$_"} @containertags;
    }
    push @containertags, @extratags if @extratags;
    $ret->{'container_tags'} = [ unify(@containertags) ] if @containertags;
  }
  if ($obsprofiles) {
    if (@$obsprofiles) {
      $ret->{'profiles'} = [ unify(@$obsprofiles) ];
    } else {
      $ret->{'exclarch'} = [];		# all profiles excluded
    }
  }
  return $ret;
}

sub parse {
  my ($cf, $fn) = @_;

  local *F;
  open(F, '<', $fn) || die("$fn: $!\n");
  my $xml = '';
  1 while sysread(F, $xml, 4096, length($xml)) > 0;
  close F;
  $cf ||= {};
  my $d;
  eval { $d = kiwiparse($xml, ($cf->{'arch'} || ''), $cf->{'buildflavor'}, $cf->{'buildrelease'}, 0) };
  if ($@) {
    my $err = $@;
    chomp $err;
    return {'error' => $err};
  }
  return $d;
}

sub show {
  my ($fn, $field, $arch, $buildflavor) = @ARGV;
  local $urlmapper = sub { return $_[0] };
  my $cf = {'arch' => $arch};
  $cf->{'buildflavor'} = $buildflavor if defined $buildflavor;
  my $d = parse($cf, $fn);
  die("$d->{'error'}\n") if $d->{'error'};
  if ($field eq 'profiles' && $d->{'exclarch'} && !@{$d->{'exclarch'}}) {
    print "__excluded\n";
    return;
  }
  my $x = $d->{$field};
  $x = [ $x ] unless ref $x;
  print "@$x\n";
}

sub showcontainerinfo {
  my ($disturl, $arch, $buildflavor, $release);
  while (@ARGV) {
    if (@ARGV > 2 && $ARGV[0] eq '--disturl') {
      (undef, $disturl) = splice(@ARGV, 0, 2);
    } elsif (@ARGV > 2 && $ARGV[0] eq '--arch') {
      (undef, $arch) = splice(@ARGV, 0, 2);
    } elsif (@ARGV > 2 && $ARGV[0] eq '--buildflavor') {
      (undef, $buildflavor) = splice(@ARGV, 0, 2);
    } elsif (@ARGV > 2 && $ARGV[0] eq '--release') {
      (undef, $release) = splice(@ARGV, 0, 2);
    } else {
      last;
    }
  }
  my ($fn, $image) = @ARGV;
  local $urlmapper = sub { return $_[0] };
  my $cf = {};
  $cf->{'arch'} = $arch if defined $arch;
  $cf->{'buildflavor'} = $buildflavor if defined $buildflavor;
  $cf->{'buildrelease'} = $release if defined $release;
  my $d = parse($cf, $fn);
  die("$d->{'error'}\n") if $d->{'error'};
  $image =~ s/.*\/// if defined $image;
  my @repos;
  for my $repo (@{$d->{'imagerepos'} || []}) {
    push @repos, { 'url' => $repo->{'url'}, '_type' => {'priority' => 'number'} };
    $repos[-1]->{'priority'} = $repo->{'priority'} if defined $repo->{'priority'};
  }
  my $buildtime = time();
  my $containerinfo = {
    'name' => $d->{'name'},
    'buildtime' => $buildtime,
    '_type' => {'buildtime' => 'number'},
  };
  $containerinfo->{'version'} = $d->{'version'} if defined $d->{'version'};
  $containerinfo->{'release'} = $release if defined $release;
  $containerinfo->{'tags'} = $d->{'container_tags'} if @{$d->{'container_tags'} || []};
  $containerinfo->{'repos'} = \@repos if @repos;
  $containerinfo->{'file'} = $image if defined $image;
  $containerinfo->{'disturl'} = $disturl if defined $disturl;
  $containerinfo->{'milestone'} = $d->{'milestone'} if defined $d->{'milestone'};
  print Build::SimpleJSON::unparse($containerinfo)."\n";
}

# not implemented yet.
sub queryiso {
  my ($handle, %opts) = @_;
  return {};
}

sub queryhdrmd5 {
  my ($bin) = @_;
  die("Build::Kiwi::queryhdrmd5 unimplemented.\n");
}

1;
