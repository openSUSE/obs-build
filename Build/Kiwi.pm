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

our $bootcallback;
our $urlmapper;

sub unify {
  my %h = map {$_ => 1} @_;
  return grep(delete($h{$_}), @_);
}

sub findFallBackArchs {
  my ($fallbackArchXML, $arch) = @_;
  my @fa;

  for my $a (@{$fallbackArchXML->{'arch'}||[]}) {
    if ( $a->{'id'} eq $arch && $a->{'fallback'} ) {
      @fa = unify( $a->{'fallback'}, findFallBackArchs($fallbackArchXML, $a->{'fallback'}));
    }
  }

  return @fa
}

# sles10 perl does not have the version.pm
# implement own hack
sub versionstring {
  my ($str) = @_;
  my @xstr = split (/\./,$str);
  my $result = 0;
  while (my $digit = shift(@xstr)) {
    $result = $result * 100;
    $result += $digit;
  }
  return $result;
}

sub kiwiparse {
  my ($xml, $arch, $count) = @_;
  $count ||= 0;
  die("kiwi config inclusion depth limit reached\n") if $count++ > 10;

  my $ret = {};
  my @types;
  my @repos;
  my @bootrepos;
  my @packages;
  my @extrasources;
  my @requiredarch;
  my $schemaversion = 0;
  my $schemaversion56 = versionstring("5.6");
  my $kiwi = Build::SimpleXML::parse($xml);
  die("not a kiwi config\n") unless $kiwi && $kiwi->{'image'};
  $kiwi = $kiwi->{'image'}->[0];
  $schemaversion = versionstring($kiwi->{'schemaversion'}) if $kiwi->{'schemaversion'}; 
  $ret->{'filename'} = $kiwi->{'name'} if $kiwi->{'name'};
  my $description = (($kiwi->{'description'} || [])->[0]) || {};
  if ($description->{'specification'}) {
    $ret->{'name'} = $description->{'specification'}->[0]->{'_content'};
  }
  # take default version setting
  my $preferences = ($kiwi->{'preferences'} || []);
  if ($preferences->[0]->{'version'}) {
    $ret->{'version'} = $preferences->[0]->{'version'}->[0]->{'_content'};
  }
  for my $pref (@{$preferences || []}) {
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
      push @packages, "kiwi-filesystem:$type->{'filesystem'}" if $type->{'filesystem'};
      if (defined $type->{'boot'}) {
        if ($type->{'boot'} =~ /^obs:\/\/\/?([^\/]+)\/([^\/]+)\/?$/) {
          next unless $bootcallback;
          my ($bootxml, $xsrc) = $bootcallback->($1, $2);
          next unless $bootxml;
          push @extrasources, $xsrc if $xsrc;
          my $bret = kiwiparse($bootxml, $arch, $count);
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

  my $instsource = ($kiwi->{'instsource'} || [])->[0];
  if ($instsource) {
    for my $repository(sort {$a->{priority} <=> $b->{priority}} @{$instsource->{'instrepo'} || []}) {
      my $kiwisource = ($repository->{'source'} || [])->[0];
      if ($kiwisource->{'path'} eq 'obsrepositories:/') {
         # special case, OBS will expand it.
         push @repos, '_obsrepositories';
         next;
      }
      if ($kiwisource->{'path'} =~ /^obs:\/\/\/?([^\/]+)\/([^\/]+)\/?$/) {
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
      }
    }
    if ($instsource->{'architectures'}) {
      my $a = $instsource->{'architectures'}->[0] || {};
      for my $ra (@{$a->{'requiredarch'} || []}) {
	push @requiredarch, $ra->{'ref'} if defined $ra->{'ref'};
      }
    }
  }

  # set default values for priority
  for (@{$kiwi->{'repository'} || []}) {
    next if defined $_->{'priority'};
    if ($preferences->[0]->{'packagemanager'}->[0]->{'_content'} eq 'smart') {
       $_->{'priority'} = 0;
    } else {
       $_->{'priority'} = 99;
    }
  }
  my @repositories = sort {$a->{'priority'} <=> $b->{'priority'}} @{$kiwi->{'repository'} || []};
  if ($preferences->[0]->{'packagemanager'}->[0]->{'_content'} eq 'smart') {
    @repositories = reverse @repositories;
  }
  for my $repository (@repositories) {
    my $kiwisource = ($repository->{'source'} || [])->[0];
    next if $kiwisource->{'path'} eq '/var/lib/empty';	# grr
    if ($kiwisource->{'path'} eq 'obsrepositories:/') {
      push @repos, '_obsrepositories';
      next;
    }
    if ($kiwisource->{'path'} =~ /^obs:\/\/\/?([^\/]+)\/([^\/]+)\/?$/) {
      push @repos, "$1/$2";
    } else {
      my $prp;
      $prp = $urlmapper->($kiwisource->{'path'}) if $urlmapper;
      die("repo url not using obs:/ scheme: $kiwisource->{'path'}\n") unless $prp;
      push @repos, $prp;
    }
  }

  # Find packages and possible additional required architectures
  my @additionalarchs;
  my @pkgs;
  for my $pattern (@{$kiwi->{'opensusePatterns'}}) {
    push @pkgs, @{"pattern:$pattern->{'package'}"} if $pattern->{'package'};
  }
  for my $packages (@{$kiwi->{'packages'}}) {
    next if $packages->{'type'} and $packages->{'type'} ne 'image' and $packages->{'type'} ne 'bootstrap';
    push @pkgs, @{$packages->{'package'}} if $packages->{'package'};
  }
  if ($instsource) {
    push @pkgs, @{$instsource->{'metadata'}->[0]->{'repopackage'} || []} if $instsource->{'metadata'};
    push @pkgs, @{$instsource->{'repopackages'}->[0]->{'repopackage'} || []} if $instsource->{'repopackages'};
  }
  @pkgs = unify(@pkgs);
  for my $package (@pkgs) {
    # filter packages, which are not targeted for the wanted plattform
    if ($package->{'arch'}) {
      my $valid=undef;
      if (@requiredarch) {
        # this is a product
        foreach my $ma(@requiredarch) {
          foreach my $pa(split(",", $package->{'arch'})) {
            $valid = 1 if $ma eq $pa;
          }
        }
      } else {
        # live appliance
        my $ma = $arch;
        $ma =~ s/i[456]86/i386/;
        foreach my $pa(split(",", $package->{'arch'})) {
          $pa =~ s/i[456]86/i386/;
          $valid = 1 if $ma eq $pa;
        }
      }
      next unless $valid;
    }

    # not nice, but optimizes our build dependencies
    # FIXME: design a real blacklist option in kiwi
    if ($package->{'onlyarch'} && $package->{'onlyarch'} eq "skipit") {
       push @packages, "-".$package->{'name'};
       next;
    }
    # handle replaces as buildignore
    if ($package->{'replaces'}) {
       push @packages, "-".$package->{'replaces'};
    }

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
  
  my @fallbackarchs;
  for my $arch (@requiredarch) {
    push @fallbackarchs, findFallBackArchs($instsource->{'architectures'}[0], $arch) if $instsource->{'architectures'}[0];
  }
  @requiredarch = unify(@requiredarch, @fallbackarchs);

  if (!$instsource) {
    my $packman = $preferences->[0]->{'packagemanager'}->[0]->{'_content'};
    push @packages, "kiwi-packagemanager:$packman";
  } else {
    push @packages, "kiwi-packagemanager:instsource";
  }

  $ret->{'exclarch'} = [ unify(@requiredarch) ] if @requiredarch;
  $ret->{'deps'} = [ unify(@packages) ];
  $ret->{'path'} = [ unify(@repos, @bootrepos) ];
  $ret->{'imagetype'} = [ unify(@types) ];
  $ret->{'extrasource'} = \@extrasources if @extrasources;
  for (@{$ret->{'path'}}) {
    my @s = split('/', $_, 2);
    $_ = {'project' => $s[0], 'repository' => $s[1]};
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
  eval {
    $d = kiwiparse($xml, ($cf->{'arch'} || ''));
  };
  if ($@) {
    my $err = $@;
    $err =~ s/^\n$//s;
    return {'error' => $err};
  }
  return $d;
}

sub show {
  my ($fn, $field, $arch) = @ARGV;
  local $urlmapper = sub { return $_[0] };
  my $cf = {'arch' => $arch};
  my $d = parse($cf, $fn);
  die("$d->{'error'}\n") if $d->{'error'};
  my $x = $d->{$field};
  $x = [ $x ] unless ref $x;
  print "@$x\n";
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
