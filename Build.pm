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

package Build;

use strict;
use Digest::MD5;
use Build::Rpm;
use Build::Intrepo;
use Build::Expand;
use POSIX qw(strftime);
#use Data::Dumper;

our $expand_dbg;
*expand_dbg = *Build::Expand::expand_dbg;

our $do_rpm;
our $do_deb;
our $do_kiwi;
our $do_arch;
our $do_collax;
our $do_livebuild;
our $do_snapcraft;
our $do_appimage;
our $do_docker;
our $do_fissile;
our $do_helm;
our $do_flatpak;

sub import {
  for (@_) {
    $do_rpm = 1 if $_ eq ':rpm';
    $do_deb = 1 if $_ eq ':deb';
    $do_kiwi = 1 if $_ eq ':kiwi';
    $do_arch = 1 if $_ eq ':arch';
    $do_collax = 1 if $_ eq ':collax';
    $do_livebuild = 1 if $_ eq ':livebuild';
    $do_snapcraft = 1 if $_ eq ':snapcraft';
    $do_appimage = 1 if $_ eq ':appimage';
    $do_docker = 1 if $_ eq ':docker';
    $do_fissile = 1 if $_ eq ':fissile';
    $do_helm = 1 if $_ eq ':helm';
    $do_flatpak = 1 if $_ eq ':flatpak';
  }
  $do_rpm = $do_deb = $do_kiwi = $do_arch = $do_collax = $do_livebuild = $do_snapcraft = $do_appimage = $do_docker = $do_fissile = $do_helm = $do_flatpak = 1 if !$do_rpm && !$do_deb && !$do_kiwi && !$do_arch && !$do_collax && !$do_livebuild && !$do_snapcraft && !$do_appimage && !$do_docker && !$do_fissile && !$do_helm && !$do_flatpak;

  if ($do_deb) {
    require Build::Deb;
  }
  if ($do_kiwi) {
    require Build::Kiwi;
  }
  if ($do_arch) {
    require Build::Arch;
  }
  if ($do_collax) {
    require Build::Collax;
  }
  if ($do_livebuild) {
    require Build::LiveBuild;
  }
  if ($do_snapcraft) {
    require Build::Snapcraft;
  }
  if ($do_appimage) {
    require Build::Appimage;
  }
  if ($do_docker) {
    require Build::Docker;
  }
  if ($do_fissile) {
    require Build::Fissile;
  }
  if ($do_helm) {
    require Build::Helm;
  }
  if ($do_flatpak) {
    require Build::Flatpak;
  }
}

package Build::Features;
our $preinstallimage = 1;	# on sale now
package Build;

# this is synced with rpm 4.13.0. The additional architectures of arm behind the spaces are
# from MeeGo project. They don't exist elsewhere, but don't conflict either luckily
my $std_macros = q{
%define nil
%define ix86    i386 i486 i586 i686 pentium3 pentium4 athlon geode
%define arm     armv3l armv4b armv4l armv4tl armv5b armv5l armv5teb armv5tel armv5tejl armv6l armv6hl armv7l armv7hl armv7hnl       armv5el armv5eb armv6el armv6eb armv7el armv7eb armv7nhl armv8el
%define arml    armv3l armv4l armv5l armv5tel armv6l armv6hl armv7l armv7hl armv7hnl
%define armb    armv4b armv5b armv5teb
%define arm64   aarch64
%define mips32  mips mipsel mipsr6 mipsr6el
%define mips64  mips64 mips64el mips64r6 mips64r6el
%define mipseb  mips mipsr6 mips64 mips64r6
%define mipsel  mipsel mipsr6el mips64el mips64r6el
%define mips    %{mips32} %{mips64}
%define sparc   sparc sparcv8 sparcv9 sparcv9v sparc64 sparc64v
%define alpha   alpha alphaev56 alphaev6 alphaev67
%define power64 ppc64 ppc64p7 ppc64le
%define riscv32 riscv32
%define riscv64 riscv64
%define riscv128 riscv128
%define riscv   %{riscv32} %{riscv64} %{riscv128}
};

my %subst_defaults = (
  # defaults live-build package dependencies base on 4.0~a26 gathered with:
  # grep Check_package -r /usr/lib/live/build
  'build-packages:livebuild' => [
    'apt-utils', 'dctrl-tools', 'debconf', 'dosfstools', 'e2fsprogs', 'grub',
    'librsvg2-bin', 'live-boot', 'live-config', 'mtd-tools', 'parted',
    'squashfs-tools', 'syslinux', 'syslinux-common', 'wget', 'xorriso', 'zsync',
  ],
  'build-packages:helm' => [
    'helm',
  ],
  'build-packages:flatpak' => [
    'flatpak', 'flatpak-builder', 'fuse', 'unzip', 'gzip', 'xz', 'elfutils',
    'gdk-pixbuf-loader-rsvg', 'perl(YAML::LibYAML)',
  ],
  'system-packages:livebuild' => [
    'apt-utils', 'cpio', 'dpkg-dev', 'live-build', 'lsb-release', 'tar',
  ],
  'system-packages:mock' => [
    'mock', 'system-packages:repo-creation',
  ],
  'system-packages:debootstrap' => [
    'debootstrap', 'lsb-release',
  ],
  'system-packages:kiwi-image' => [
    'kiwi', 'tar', 'system-packages:repo-creation',
  ],
  'system-packages:kiwi-product' => [
    'kiwi',
  ],
  'system-packages:docker' => [
    'docker', 'system-packages:repo-creation',
  ],
  'system-packages:podman' => [
    'podman', 'buildah', 'system-packages:repo-creation',
  ],
  'system-packages:fissile' => [
    'docker', # TODO: Add fissile here as soon as it is packaged
  ],
  'system-packages:deltarpm' => [
    'deltarpm',
  ],
  'system-packages:repo-creation:rpm' => [
    'createrepo',
  ],
  'system-packages:repo-creation:deb' => [
    'dpkg-dev',
  ],
  'system-packages:repo-creation:arch' => [
    'pacman',
  ],
);

sub unify {
  my %h = map {$_ => 1} @_;
  return grep(delete($h{$_}), @_);
}

sub init_helper_hashes {
  my ($config) = @_;

  $config->{'preferh'} = { map {$_ => 1} @{$config->{'prefer'}} };

  my %ignore;
  for (@{$config->{'ignore'}}) {
    if (!/:/) {
      $ignore{$_} = 1;
      next;
    }
    my @s = split(/[,:]/, $_);
    my $s = shift @s;
    $ignore{"$s:$_"} = 1 for @s;
  }
  $config->{'ignoreh'} = \%ignore;

  my %conflicts;
  for (@{$config->{'conflict'}}) {
    my @s = split(/[,:]/, $_);
    my $s = shift @s;
    push @{$conflicts{$s}}, @s;
    push @{$conflicts{$_}}, $s for @s;
  }
  for (keys %conflicts) {
    $conflicts{$_} = [ unify(@{$conflicts{$_}}) ]
  }
  $config->{'conflicth'} = \%conflicts;
}

# 'canonicalize' dist string as found in rpm dist tags
sub dist_canon($$) {
  my ($rpmdist, $arch) = @_;
  $rpmdist = lc($rpmdist);
  $rpmdist =~ s/-/_/g;
  $rpmdist =~ s/opensuse/suse linux/;
  my $rpmdista;
  if ($rpmdist =~ /\(/) {
    $rpmdista = $rpmdist;
    $rpmdista =~ s/.*\(//;
    $rpmdista =~ s/\).*//;
  } else {
    $rpmdista = $arch;
  }
  $rpmdista =~ s/i[456]86/i386/;
  $rpmdist = '' unless $rpmdista =~ /^(i386|x86_64|ia64|ppc|ppc64|ppc64le|s390|s390x)$/;
  my $dist = 'default';
  if ($rpmdist =~ /unitedlinux 1\.0.*/) {
    $dist = "ul1-$rpmdista";
  } elsif ($rpmdist =~ /suse sles_(\d+)/) {
    $dist = "sles$1-$rpmdista";
  } elsif ($rpmdist =~ /suse linux enterprise (\d+)/) {
    $dist = "sles$1-$rpmdista";
  } elsif ($rpmdist =~ /suse linux (\d+)\.(\d+)\.[4-9]\d/) {
    # alpha version
    $dist = "$1.".($2 + 1)."-$rpmdista";
  } elsif ($rpmdist =~ /suse linux (?:leap )?(\d+\.\d+)/) {
    $dist = "$1-$rpmdista";
  }
  return $dist;
}

# combine multiple config files into a single config
sub combine_configs {
  my (@c) = @_;
  my $config = '';
  my $macros = '';
  for my $c (@c) {
    $c =~ s/\n?$/\n/s if $c ne '';
    if ($c =~ /^\s*:macros\s*$/im) {
      # probably multiple macro sections with %if statements
      # flush out macros
      $config .= "\nMacros:\n$macros:Macros\n\n" if $macros ne '';
      $macros = '';
      my $s1 = '\A(.*^\s*:macros\s*$)(.*?)\z';  # should always match
      if ($c =~ /$s1/msi) {
        $config .= $1;
        $c = $2;
      } else {
        $config .= $c;
        $c = '';
      }
    }
    if ($c =~ /^(.*\n)?\s*macros:[^\n]*\n(.*)/si) {
      # has single macro section at end. cumulate
      $c = defined($1) ? $1 : '';
      $macros .= $2;
    }
    $config .= $c;
  }
  $config .= "\nMacros:\n$macros" if $macros ne '';
  return $config;
}

sub find_config_file {
  my ($dist, $configdir) = @_;

  die("Please specify a distribution!\n") unless defined $dist;
  if ($dist !~ /\//) {
    my $saved = $dist;
    $configdir = '.' unless defined $configdir;
    $dist =~ s/-.*//;
    $dist = "sl$dist" if $dist =~ /^\d/;
    $dist = "$configdir/$dist.conf";
    if (! -e $dist) {
      $dist =~ s/-.*//;
      $dist = "sl$dist" if $dist =~ /^\d/;
      $dist = "$configdir/$dist.conf";
    }
    if (! -e $dist) {
      warn "$saved.conf not found, using default.conf\n" unless $saved eq 'default';
      $dist = "$configdir/default.conf";
    }
  }
  die("$dist: $!\n") unless -e $dist;
  return $dist;
}

sub slurp_config_file {
  my ($file, $seen) = @_;
  local *CONF;
  die("$file: $!\n") unless open(CONF, '<', $file);
  my @config = <CONF>;
  close CONF;
  chomp @config;
  if (@config && $config[0] =~ /^#!PrependConfigFile:\s*([^\.\/][^\/]*?)\s*$/) {
    my $otherfile = $1;
    if (!$seen) {
      $seen = {};
      $seen->{$1} = 1 if $file =~ /([^\/]*)$/;
    }
    if (!$seen->{$otherfile}++) {
      $file =~ s/[^\/]*$/$otherfile/;
      my $otherconfig = slurp_config_file($file, $seen) || [];
      return [ split("\n", combine_configs(join("\n", @$otherconfig), join("\n", @config))) ];
    }
  }
  return \@config;
}

sub read_config_dist {
  my ($dist, $archpath, $configdir) = @_;
  $dist = find_config_file($dist, $configdir);
  my $arch = $archpath;
  $arch = 'noarch' unless defined $arch;
  $arch =~ s/:.*//;
  $arch = 'noarch' if $arch eq '';
  my $cfile = slurp_config_file($dist);
  my $cf = read_config($arch, $cfile);
  die("$dist: parse error\n") unless $cf;
  return $cf;
}

sub read_config {
  my ($arch, $cfile) = @_;
  my @macros = split("\n", $std_macros);
  push @macros, "%define _target_cpu $arch";
  push @macros, "%define _target_os linux";
  my $config = {'macros' => \@macros, 'arch' => $arch};
  my @config;
  if (ref($cfile)) {
    @config = @$cfile;
  } elsif (defined($cfile)) {
    local *CONF;
    return undef unless open(CONF, '<', $cfile);
    @config = <CONF>;
    close CONF;
    chomp @config;
  }
  # create verbatim macro blobs
  my @newconfig;
  while (@config) {
    push @newconfig, shift @config;
    next unless $newconfig[-1] =~ /^\s*macros:\s*$/si;
    $newconfig[-1] = "macros:\n";
    while (@config) {
      my $l = shift @config;
      last if $l =~ /^\s*:macros\s*$/si;
      $newconfig[-1] .= "$l\n";
    }
    $newconfig[-1] = [ $newconfig[-1] ];	# verbatim quote, see Rpm.pm
  }
  my @spec;
  $config->{'save_expanded'} = 1;
  Build::Rpm::parse($config, \@newconfig, \@spec);
  delete $config->{'save_expanded'};
  $config->{'preinstall'} = [];
  $config->{'vminstall'} = [];
  $config->{'cbpreinstall'} = [];
  $config->{'cbinstall'} = [];
  $config->{'runscripts'} = [];
  $config->{'required'} = [];
  $config->{'support'} = [];
  $config->{'keep'} = [];
  $config->{'prefer'} = [];
  $config->{'ignore'} = [];
  $config->{'conflict'} = [];
  $config->{'alsonative'} = [];
  $config->{'onlynative'} = [];
  $config->{'substitute'} = {};
  $config->{'substitute_vers'} = {};
  $config->{'optflags'} = {};
  $config->{'order'} = {};
  $config->{'exportfilter'} = {};
  $config->{'publishfilter'} = [];
  $config->{'rawmacros'} = '';
  $config->{'release'} = '<CI_CNT>.<B_CNT>';
  $config->{'repotype'} = [];
  $config->{'patterntype'} = [];
  $config->{'fileprovides'} = {};
  $config->{'constraint'} = [];
  $config->{'expandflags'} = [];
  $config->{'buildflags'} = [];
  $config->{'publishflags'} = [];
  $config->{'singleexport'} = '';
  $config->{'repourl'} = [];
  $config->{'registryurl'} = [];
  $config->{'assetsurl'} = [];
  for my $l (@spec) {
    $l = $l->[1] if ref $l;
    next unless defined $l;
    my @l = split(' ', $l);
    next unless @l;
    my $ll = shift @l;
    my $l0 = lc($ll);
    if ($l0 eq 'macros:') {
      $l =~ s/.*?\n//s;
      if ($l =~ /^!\n/s) {
	$config->{'rawmacros'} = substr($l, 2);
      } else {
	$config->{'rawmacros'} .= $l;
      }
      next;
    }
    if ($l0 eq 'distmacro:') {
      @l = split(' ', $l, 2);
      push @macros, "%define $l[1]" if @l == 2;
      next;
    }
    if ($l0 eq 'preinstall:' || $l0 eq 'vminstall:' || $l0 eq 'required:' || $l0 eq 'support:' || $l0 eq 'keep:' || $l0 eq 'prefer:' || $l0 eq 'ignore:' || $l0 eq 'conflict:' || $l0 eq 'runscripts:' || $l0 eq 'expandflags:' || $l0 eq 'buildflags:' || $l0 eq 'publishflags:' || $l0 eq 'repourl:' || $l0 eq 'registryurl:' || $l0 eq 'assetsurl:' || $l0 eq 'onlynative:' || $l0 eq 'alsonative:') {
      my $t = substr($l0, 0, -1);
      for my $l (@l) {
	if ($l eq '!*') {
	  $config->{$t} = [];
	} elsif ($l =~ /^!/) {
	  $config->{$t} = [ grep {"!$_" ne $l} @{$config->{$t}} ];
	} else {
	  push @{$config->{$t}}, $l;
	}
      }
    } elsif ($l0 eq 'substitute:') {
      next unless @l;
      $ll = shift @l;
      if ($ll eq '!*') {
	$config->{'substitute'} = {};
      } elsif ($ll =~ /^!(.*)$/) {
	delete $config->{'substitute'}->{$1};
      } else {
	$config->{'substitute'}->{$ll} = [ @l ];
      }
    } elsif ($l0 eq 'fileprovides:') {
      next unless @l;
      $ll = shift @l;
      if ($ll eq '!*') {
	$config->{'fileprovides'} = {};
      } elsif ($ll =~ /^!(.*)$/) {
	delete $config->{'fileprovides'}->{$1};
      } else {
	$config->{'fileprovides'}->{$ll} = [ @l ];
      }
    } elsif ($l0 eq 'exportfilter:') {
      next unless @l;
      $ll = shift @l;
      $config->{'exportfilter'}->{$ll} = [ @l ];
    } elsif ($l0 eq 'publishfilter:') {
      $config->{'publishfilter'} = [ @l ];
    } elsif ($l0 eq 'optflags:') {
      next unless @l;
      $ll = shift @l;
      $config->{'optflags'}->{$ll} = join(' ', @l);
    } elsif ($l0 eq 'order:') {
      for my $l (@l) {
	if ($l eq '!*') {
	  $config->{'order'} = {};
	} elsif ($l =~ /^!(.*)$/) {
	  delete $config->{'order'}->{$1};
	} else {
	  $config->{'order'}->{$l} = 1;
	}
      }
    } elsif ($l0 eq 'repotype:') { # type of generated repository data
      $config->{'repotype'} = [ @l ];
    } elsif ($l0 eq 'type:') { # kind of recipe system (spec,dsc,arch,kiwi,...)
      $config->{'type'} = $l[0];
    } elsif ($l0 eq 'buildengine:') { # build engine (build,mock)
      $config->{'buildengine'} = $l[0];
    } elsif ($l0 eq 'binarytype:') { # kind of binary packages (rpm,deb,arch,...)
      $config->{'binarytype'} = $l[0];
    } elsif ($l0 eq 'patterntype:') { # kind of generated patterns in repository
      $config->{'patterntype'} = [ @l ];
    } elsif ($l0 eq 'release:') {
      $config->{'release'} = $l[0];
      $config->{'release@'} = [ @l ];
    } elsif ($l0 eq 'cicntstart:') {
      $config->{'cicntstart'} = $l[0];
    } elsif ($l0 eq 'releaseprg:') {
      $config->{'releaseprg'} = $l[0];
    } elsif ($l0 eq 'releasesuffix:') {
      $config->{'releasesuffix'} = join(' ', @l);
    } elsif ($l0 eq 'changetarget:' || $l0 eq 'target:') {
      $config->{'target'} = join(' ', @l);
      push @macros, "%define _target_cpu ".(split('-', $config->{'target'}))[0] if $config->{'target'};
    } elsif ($l0 eq 'hostarch:') {
      $config->{'hostarch'} = join(' ', @l);
    } elsif ($l0 eq 'constraint:') {
      my $l = join(' ', @l);
      if ($l eq '!*') {
	$config->{'constraint'} = [];
      } else {
	push @{$config->{'constraint'}}, $l;
      }
    } elsif ($l0 eq 'singleexport:') {
      $config->{'singleexport'} = $l[0]; # avoid to export multiple package container in maintenance_release projects
    } elsif ($l0 !~ /^[#%]/) {
      warn("unknown keyword in config: $l0\n");
    }
  }
  for my $l (qw{preinstall vminstall required support keep runscripts repotype patterntype}) {
    $config->{$l} = [ unify(@{$config->{$l}}) ];
  }
  init_helper_hashes($config);
  # calculate type and binarytype
  if (!$config->{'type'}) {
    # Fallback to old guessing method if no type (spec, dsc or kiwi) is defined
    if (grep {$_ eq 'rpm'} @{$config->{'preinstall'} || []}) {
      $config->{'type'} = 'spec';
    } elsif (grep {$_ eq 'debianutils'} @{$config->{'preinstall'} || []}) {
      $config->{'type'} = 'dsc';
    } elsif (grep {$_ eq 'pacman'} @{$config->{'preinstall'} || []}) {
      $config->{'type'} = 'arch';
    }
    $config->{'type'} ||= 'UNDEFINED';
  }
  if (!$config->{'binarytype'}) {
    $config->{'binarytype'} = 'rpm' if $config->{'type'} eq 'spec';
    $config->{'binarytype'} = 'deb' if $config->{'type'} eq 'dsc' || $config->{'type'} eq 'collax' || $config->{'type'} eq 'livebuild';
    $config->{'binarytype'} = 'arch' if $config->{'type'} eq 'arch';
    if (grep {$_ eq $config->{'type'}} qw{snapcraft appimage docker fissile kiwi}){
      if (grep {$_ eq 'rpm'} @{$config->{'preinstall'} || []}) {
        $config->{'binarytype'} = 'rpm';
      } elsif (grep {$_ eq 'debianutils'} @{$config->{'preinstall'} || []}) {
        $config->{'binarytype'} = 'deb';
      } elsif (grep {$_ eq 'pacman'} @{$config->{'preinstall'} || []}) {
        $config->{'binarytype'} = 'arch';
      }
    }
    $config->{'binarytype'} ||= 'UNDEFINED';
  }
  # add default substitutes
  if (!$config->{'substitute'}->{'system-packages:repo-creation'}) {
    $config->{'substitute'}->{'system-packages:repo-creation'} = $subst_defaults{"system-packages:repo-creation:$config->{'binarytype'}"} if $subst_defaults{"system-packages:repo-creation:$config->{'binarytype'}"};
  }
  # create substitute_vers hash from substitute entries
  for my $l (keys %{$config->{'substitute'}}) {
    $config->{'substitute_vers'}->{$l} = [ map {/^(.*?)(=)?$/g} unify(@{$config->{'substitute'}->{$l}}) ];
    $config->{'substitute'}->{$l} = [ unify(@{$config->{'substitute'}->{$l}}) ];
    s/=$// for @{$config->{'substitute'}->{$l}};
  }
  # add rawmacros to our macro list
  if ($config->{'rawmacros'} ne '') {
    for my $rm (split("\n", $config->{'rawmacros'})) {
      if (@macros && $macros[-1] =~ /\\$/) {
	if ($rm =~ /\\$/) {
	  push @macros, '...\\';
	} else {
	  push @macros, '...';
	}
      } elsif ($rm !~ /^%/) {
	push @macros, $rm;
      } else {
	push @macros, "%define ".substr($rm, 1);
      }
    }
  }
  # extract some helper hashes for the flags
  my %modules;
  for (@{$config->{'expandflags'} || []}) {
    if (/^([^:]+):(.*)$/s) {
      $config->{"expandflags:$1"} = $2;
      $modules{$2} = 1 if $1 eq 'module';
    } else {
      $config->{"expandflags:$_"} = 1;
    }
  }
  for (@{$config->{'buildflags'} || []}) {
    if (/^([^:]+):(.*)$/s) {
      $config->{"buildflags:$1"} = $2;
    } else {
      $config->{"buildflags:$_"} = 1;
    }
  }
  for (@{$config->{'publishflags'} || []}) {
    if (/^([^:]+):(.*)$/s) {
      $config->{"publishflags:$1"} = $2;
    } else {
      $config->{"publishflags:$_"} = 1;
    }
  }
  $config->{'modules'} = [ sort keys %modules ] if %modules;
  return $config;
}

sub add_distmacro {
  my ($config, $name_value) = @_;
  push @{$config->{'macros'}}, "%define $name_value\n";
}

sub gettargetarchos {
  my ($config) = @_;
  my ($arch, $os);
  for (@{$config->{'macros'} || []}) {
    $arch = $1 if /^%define _target_cpu (\S+)/;
    $os = $1 if /^%define _target_os (\S+)/;
  }
  return ($arch, $os);
}

sub do_subst {
  my ($config, @deps) = @_;
  my @res;
  my %done;
  my $subst = $config->{'substitute'};
  while (@deps) {
    my $d = shift @deps;
    next if $done{$d};
    my $ds = $d;
    $ds =~ s/\s*[<=>].*$//s;
    if ($subst->{$ds}) {
      unshift @deps, @{$subst->{$ds}};
      push @res, $d if grep {$_ eq $ds} @{$subst->{$ds}};
    } else {
      push @res, $d;
    }
    $done{$d} = 1;
  }
  return @res;
}

sub do_subst_vers {
  my ($config, @deps) = @_;
  my @res;
  my %done;
  my $subst = $config->{'substitute_vers'};
  while (@deps) {
    my ($d, $dv) = splice(@deps, 0, 2);
    next if $done{$d};
    if ($subst->{$d}) {
      unshift @deps, map {defined($_) && $_ eq '=' ? $dv : $_} @{$subst->{$d}};
      push @res, $d, $dv if grep {defined($_) && $_ eq $d} @{$subst->{$d}};
    } else {
      push @res, $d, $dv;
    }
    $done{$d} = 1;
  }
  return @res;
}

# expand the preinstalls/vminstalls
sub expandpreinstalls {
  my ($config) = @_;
  return if !$config->{'expandflags:preinstallexpand'} || $config->{'preinstallisexpanded'};
  my (@pre, @vm);
  if (@{$config->{'preinstall'} || []}) {
    my $c = $config;
    @pre = expand($c, @{$config->{'preinstall'} || []});
    return "preinstalls: $pre[0]" unless shift @pre;
    @pre = sort(@pre);
  }
  if ($config->{'no_vminstall_expand'}) {
    @vm = ('expandpreinstalls_error');
  } elsif (@{$config->{'vminstall'} || []}) {
    my %pre = map {$_ => 1} @pre;
    my %vmx = map {+"-$_" => 1} @{$config->{'vminstall'} || []};
    my @pren = grep {/^-/ && !$vmx{$_}} @{$config->{'preinstall'} || []};
    my $c = $config;
    @vm = expand($c, @pre, @pren, @{$config->{'vminstall'} || []});
    return "vminstalls: $vm[0]" unless shift @vm;
    @vm = sort(grep {!$pre{$_}} @vm);
  }
  $config->{'preinstall'} = \@pre;
  $config->{'vminstall'} = \@vm;
  #print STDERR "pre: @pre\n";
  #print STDERR "vm: @vm\n";
  $config->{'preinstallisexpanded'} = 1;
  return '';
}

# Delivers all packages which get used for building
sub get_build {
  my ($config, $subpacks, @deps) = @_;

  if ($config->{'expandflags:preinstallexpand'} && !$config->{'preinstallisexpanded'}) {
    my $err = expandpreinstalls($config);
    return (undef, $err) if $err;
  }
  my $buildtype = $config->{'type'} || '';
  my $nobasepackages;
  if (grep {$_ eq $buildtype} qw{livebuild docker kiwi fissile helm flatpak}) {
    push @deps, @{$config->{'substitute'}->{"build-packages:$buildtype"}
		  || $subst_defaults{"build-packages:$buildtype"} || []};
    if ($buildtype eq 'docker' || $buildtype eq 'kiwi') {
      $nobasepackages = 1 if $config->{"expandflags:$buildtype-nobasepackages"};
      @deps = grep {!/^kiwi-image:/} @deps if $buildtype eq 'kiwi';	# only needed for sysdeps
      @deps = grep {!/^kiwi-packagemanager:/} @deps if $buildtype eq 'kiwi' && $nobasepackages;	# only needed for sysdeps
    }
  }
  my @ndeps = grep {/^-/} @deps;
  my %ndeps = map {$_ => 1} @ndeps;
  my @directdepsend;
  if ($ndeps{'--directdepsend--'}) {
    @directdepsend = @deps;
    for (splice @deps) {
      last if $_ eq '--directdepsend--';
      push @deps, $_;
    }
    @directdepsend = grep {!/^-/} splice(@directdepsend, @deps + 1);
  }
  my @extra = (@{$config->{'required'}}, @{$config->{'support'}});
  if (@{$config->{'keep'} || []}) {
    my %keep = map {$_ => 1} (@deps, @{$config->{'keep'} || []}, @{$config->{'preinstall'}});
    for (@{$subpacks || []}) {
      next if $keep{$_};
      push @ndeps, "-$_";
      $ndeps{"-$_"} = 1;
    }
  } else {
    # new "empty keep" mode, filter subpacks from required/support
    my %subpacks = map {$_ => 1} @{$subpacks || []};
    @extra = grep {!$subpacks{$_}} @extra;
  }
  @deps = grep {!$ndeps{$_}} @deps;
  if (!$nobasepackages) {
    push @deps, @{$config->{'preinstall'}}, @extra;
    @deps = grep {!$ndeps{"-$_"}} @deps;
  }
  @deps = do_subst($config, @deps);
  @deps = grep {!$ndeps{"-$_"}} @deps;
  if (@directdepsend) {
    @directdepsend = do_subst($config, @directdepsend);
    @directdepsend = grep {!$ndeps{"-$_"}} @directdepsend;
    unshift @directdepsend, '--directdepsend--' if @directdepsend;
  }
  @deps = expand($config, @deps, @ndeps, @directdepsend);
  return @deps;
}

# Delivers all packages which get used for the cross building sysroot
sub get_sysroot {
  my ($config, $subpacks, @deps) = @_;
  my @ndeps = grep {/^-/} @deps;
  my %ndeps = map {$_ => 1} @ndeps;
  my @directdepsend;
  if ($ndeps{'--directdepsend--'}) {
    @directdepsend = @deps;
    for (splice @deps) {
      last if $_ eq '--directdepsend--';
      push @deps, $_;
    }
    @directdepsend = grep {!/^-/} splice(@directdepsend, @deps + 1);
  }
  unshift @deps, 'sysroot-packages' if $config->{'substitute'}->{'sysroot-packages'};
  @deps = grep {!$ndeps{$_}} @deps;
  @deps = do_subst($config, @deps);
  @deps = grep {!$ndeps{"-$_"}} @deps;
  if (@directdepsend) {
    @directdepsend = do_subst($config, @directdepsend);
    @directdepsend = grep {!$ndeps{"-$_"}} @directdepsend;
    unshift @directdepsend, '--directdepsend--' if @directdepsend;
  }
  @deps = expand($config, @deps, @ndeps, @directdepsend);
  return @deps;
}

# return the package needed for setting up the build environment.
# an empty result means that the packages from get_build should
# be used instead.
sub get_sysbuild {
  my ($config, $buildtype, $extradeps) = @_;
  my $engine = $config->{'buildengine'} || '';
  $buildtype ||= $config->{'type'} || '';
  my @sysdeps;
  if ($engine eq 'mock' && $buildtype eq 'spec') {
    @sysdeps = @{$config->{'substitute'}->{'system-packages:mock'} || []};
    @sysdeps = @{$subst_defaults{'system-packages:mock'} || []} unless @sysdeps;
  } elsif ($engine eq 'debootstrap' && $buildtype eq 'dsc') {
    @sysdeps = @{$config->{'substitute'}->{'system-packages:debootstrap'} || []};
    @sysdeps = @{$subst_defaults{'system-packages:debootstrap'} || []} unless @sysdeps;
  } elsif ($buildtype eq 'livebuild') {
    # packages used for build environment setup (build-recipe-livebuild deps)
    @sysdeps = @{$config->{'substitute'}->{'system-packages:livebuild'} || []};
    @sysdeps = @{$subst_defaults{'system-packages:livebuild'} || []} unless @sysdeps;
  } elsif ($buildtype eq 'kiwi-image') {
    @sysdeps = @{$config->{'substitute'}->{'system-packages:kiwi-image'} || []};
    @sysdeps = @{$config->{'substitute'}->{'kiwi-setup:image'} || []} unless @sysdeps;
    @sysdeps = @{$subst_defaults{'system-packages:kiwi-image'} || []} unless @sysdeps;
  } elsif ($buildtype eq 'kiwi-product') {
    @sysdeps = @{$config->{'substitute'}->{'system-packages:kiwi-product'} || []};
    @sysdeps = @{$config->{'substitute'}->{'kiwi-setup:product'} || []} unless @sysdeps;
    @sysdeps = @{$subst_defaults{'system-packages:kiwi-product'} || []} unless @sysdeps;
  } elsif ($engine eq 'podman' && $buildtype eq 'docker') {
    @sysdeps = @{$config->{'substitute'}->{'system-packages:podman'} || []} unless @sysdeps;
    @sysdeps = @{$subst_defaults{'system-packages:podman'} || []} unless @sysdeps;
  } elsif ($buildtype eq 'docker') {
    @sysdeps = @{$config->{'substitute'}->{'system-packages:docker'} || []} unless @sysdeps;
    @sysdeps = @{$subst_defaults{'system-packages:docker'} || []} unless @sysdeps;
  } elsif ($buildtype eq 'fissile') {
    @sysdeps = @{$config->{'substitute'}->{'system-packages:fissile'} || []} unless @sysdeps;
    @sysdeps = @{$subst_defaults{'system-packages:fissile'} || []} unless @sysdeps;
  } elsif ($buildtype eq 'deltarpm') {
    @sysdeps = @{$config->{'substitute'}->{'system-packages:deltarpm'} || []};
    @sysdeps = @{$subst_defaults{'system-packages:deltarpm'} || []} unless @sysdeps;
  }
  return () unless @sysdeps;	# no extra build environment used
  push @sysdeps, @$extradeps if $extradeps;
  if ($config->{'expandflags:preinstallexpand'} && !$config->{'preinstallisexpanded'}) {
    my $err = expandpreinstalls($config);
    return (undef, $err) if $err;
  }
  my @ndeps = grep {/^-/} @sysdeps;
  my %ndeps = map {$_ => 1} @ndeps;
  @sysdeps = grep {!$ndeps{$_}} @sysdeps;
  push @sysdeps, @{$config->{'preinstall'}}, @{$config->{'required'}};
  push @sysdeps, @{$config->{'support'}} if $buildtype eq 'kiwi-image' || $buildtype eq 'kiwi-product';	# compat to old versions
  @sysdeps = do_subst($config, @sysdeps);
  @sysdeps = grep {!$ndeps{$_}} @sysdeps;
  my $configtmp = $config;
  @sysdeps = expand($configtmp, @sysdeps, @ndeps);
  return @sysdeps unless $sysdeps[0];
  shift @sysdeps;
  @sysdeps = unify(@sysdeps, get_preinstalls($config));
  return (1, @sysdeps);
}

# Delivers all packages which shall have an influence to other package builds (get_build reduced by support packages)
sub get_deps {
  my ($config, $subpacks, @deps) = @_;
  if ($config->{'expandflags:preinstallexpand'} && !$config->{'preinstallisexpanded'}) {
    my $err = expandpreinstalls($config);
    return (undef, $err) if $err;
  }
  my @ndeps = grep {/^-/} @deps;
  my @extra = @{$config->{'required'}};
  if (@{$config->{'keep'} || []}) {
    my %keep = map {$_ => 1} (@deps, @{$config->{'keep'} || []}, @{$config->{'preinstall'}});
    for (@{$subpacks || []}) {
      push @ndeps, "-$_" unless $keep{$_};
    }
  } else {
    # new "empty keep" mode, filter subpacks from required
    my %subpacks = map {$_ => 1} @{$subpacks || []};
    @extra = grep {!$subpacks{$_}} @extra;
  }
  my %ndeps = map {$_ => 1} @ndeps;
  @deps = grep {!$ndeps{$_}} @deps;
  push @deps, @extra;
  @deps = grep {!$ndeps{"-$_"}} @deps;
  @deps = do_subst($config, @deps);
  @deps = grep {!$ndeps{"-$_"}} @deps;
  my %bdeps = map {$_ => 1} (@{$config->{'preinstall'}}, @{$config->{'support'}});
  delete $bdeps{$_} for @deps;
  @deps = expand($config, @deps, @ndeps);
  if (@deps && $deps[0]) {
    my $r = shift @deps;
    @deps = grep {!$bdeps{$_}} @deps;
    unshift @deps, $r;
  }
  return @deps;
}

sub get_preinstalls {
  my ($config) = @_;
  if ($config->{'expandflags:preinstallexpand'} && !$config->{'preinstallisexpanded'}) {
    my $err = expandpreinstalls($config);
    return ('expandpreinstalls_error') if $err;
  }
  return @{$config->{'preinstall'}};
}

sub get_vminstalls {
  my ($config) = @_;
  if ($config->{'expandflags:preinstallexpand'} && !$config->{'preinstallisexpanded'}) {
    my $err = expandpreinstalls($config);
    return ('expandpreinstalls_error') if $err;
  }
  return @{$config->{'vminstall'}};
}

sub get_runscripts {
  my ($config) = @_;
  return @{$config->{'runscripts'}};
}

### just for API compability
sub get_cbpreinstalls { return (); }
sub get_cbinstalls { return (); }

###########################################################################

sub parse_depfile {
  return Build::Intrepo::parse(@_);
}

sub readdeps {
  my ($config, $pkginfo, @depfiles) = @_;

  my $nofiledeps = %{$config->{'fileprovides'} || {}} ? 0 : 1;
  $pkginfo ||= {};
  for my $depfile (@depfiles) {
    if (ref($depfile) eq 'HASH') {
      $pkginfo->{$_} = $depfile->{$_} for keys %$depfile;
    } else {
      my $pkgs = Build::Intrepo::parse($depfile, [], 'nofiledeps' => $nofiledeps);
      $pkginfo->{$_->{'name'}} = $_ for @$pkgs;
    }
  }

  # put repository data into the build config
  my %requires;
  my %provides;
  my %pkgconflicts;
  my %pkgobsoletes;
  my %recommends;
  my %supplements;
  for my $pkgid (sort keys %$pkginfo) {
    my $pkg = $pkginfo->{$pkgid};
    $provides{$pkgid} = $pkg->{'provides'} if $pkg->{'provides'};
    $requires{$pkgid} = $pkg->{'requires'} if $pkg->{'requires'};
    $pkgconflicts{$pkgid} = $pkg->{'conflicts'} if $pkg->{'conflicts'};
    $pkgobsoletes{$pkgid} = $pkg->{'obsoletes'} if $pkg->{'obsoletes'};
    $recommends{$pkgid} = $pkg->{'recommends'} if $pkg->{'recommends'};
    $supplements{$pkgid} = $pkg->{'supplements'} if $pkg->{'supplements'};
  }
  $config->{'providesh'} = \%provides;
  $config->{'requiresh'} = \%requires;
  $config->{'pkgconflictsh'} = \%pkgconflicts;
  $config->{'pkgobsoletesh'} = \%pkgobsoletes;
  $config->{'recommendsh'} = \%recommends;
  $config->{'supplementsh'} = \%supplements;
  makewhatprovidesh($config);
}

sub writedeps {
  Build::Intrepo::writepkg(@_);
}

sub getbuildid {
  return Build::Intrepo::getbuildid(@_);
}

sub makewhatprovidesh {
  my ($config) = @_;

  my %whatprovides;
  my $provides = $config->{'providesh'};

  for my $p (keys %$provides) {
    my @pp = @{$provides->{$p}};
    s/[ <=>].*// for @pp;
    push @{$whatprovides{$_}}, $p for unify(@pp);
  }
  for my $p (keys %{$config->{'fileprovides'}}) {
    my @pp = grep {@{$provides->{$_} || []}} @{$config->{'fileprovides'}->{$p}};
    @{$whatprovides{$p}} = unify(@{$whatprovides{$p} || []}, @pp) if @pp;
  }
  $config->{'whatprovidesh'} = \%whatprovides;
}

sub setdeps {
  my ($config, $provides, $whatprovides, $requires) = @_;
  $config->{'providesh'} = $provides;
  $config->{'whatprovidesh'} = $whatprovides;
  $config->{'requiresh'} = $requires;
}

sub forgetdeps {
  my ($config) = @_;
  delete $config->{'providesh'};
  delete $config->{'whatprovidesh'};
  delete $config->{'requiresh'};
  delete $config->{'pkgconflictsh'};
  delete $config->{'pkgobsoletesh'};
  delete $config->{'recommendsh'};
  delete $config->{'supplementsh'};
}

my %addproviders_fm = (
  '>'  => 1,
  '='  => 2,
  '==' => 2,
  '>=' => 3,
  '<'  => 4,
  '<=' => 6,
);

sub matchsingledep {
  my ($p, $d, $binarytype) = @_;

  return 1 if $p eq $d;
  if ($d !~ /^(.*?)\s*([<=>]{1,2})\s*(.*?)$/) {
    # d is bare
    $d =~ s/:any$// if $binarytype eq 'deb';
    return 1 if $p eq $d;
    return 1 if $p =~ /^\Q$d\E\s*([<=>]{1,2})\s*(.*?)$/;
    return 0;
  }
  my $dn = $1;
  my $dv = $3;
  my $df = $addproviders_fm{$2};
  return 0 unless $df;
  $dn =~ s/:any$// if $binarytype eq 'deb';
  if ($p !~ /^\Q$dn\E\s*([<=>]{1,2})\s*(.*?)$/) {
    # p is bare or not matching 
    return 0 if $binarytype eq 'deb';
    return $p eq $dn ? 1 : 0;
  }
  my $pv = $2;
  my $pf = $addproviders_fm{$1};
  return 0 unless $pf;
  return 1 if $pf & $df & 5;
  if ($pv eq $dv) {
    return 0 unless $pf & $df & 2;
    return 1;
  }
  my $rr = $df == 2 ? $pf : ($df ^ 5);
  $rr &= 5 unless $pf & 2;
  # verscmp for spec and kiwi types
  my $vv;
  if ($binarytype eq 'deb') {
    $vv = Build::Deb::verscmp($pv, $dv, 1);
  } else {
    $vv = Build::Rpm::verscmp($pv, $dv, 1);
  }
  return 1 if $rr & (1 << ($vv + 1));
  return 0;
}

sub addproviders {
  my ($config, $r) = @_;

  my @p;
  my $whatprovides = $config->{'whatprovidesh'};
  $whatprovides->{$r} = \@p;
  my $binarytype = $config->{'binarytype'};
  if ($r =~ /\|/) {
    for my $or (split(/\s*\|\s*/, $r)) {
      push @p, @{$whatprovides->{$or} || addproviders($config, $or)};
    }
    @p = unify(@p) if @p > 1;
    return \@p;
  }
  if ($r !~ /^(.*?)\s*([<=>]{1,2})\s*(.*?)$/) {
    @p = @{$whatprovides->{$r} || addproviders($config, $r)} if $binarytype eq 'deb' && $r =~ s/:any$//;
    return \@p;
  }
  my $rn = $1;
  my $rv = $3;
  my $rf = $addproviders_fm{$2};
  return \@p unless $rf;
  $rn =~ s/:any$// if $binarytype eq 'deb';
  my $provides = $config->{'providesh'};
  my @rp = @{$whatprovides->{$rn} || []};
  for my $rp (@rp) {
    for my $pp (@{$provides->{$rp} || []}) {
      if ($pp eq $rn) {
	# debian: unversioned provides do not match
	next if $binarytype eq 'deb';
	push @p, $rp;
	last;
      }
      next unless $pp =~ /^\Q$rn\E\s*([<=>]{1,2})\s*(.*?)$/;
      my $pv = $2;
      my $pf = $addproviders_fm{$1};
      next unless $pf;
      if ($pf & $rf & 5) {
	push @p, $rp;
	last;
      }
      if ($pv eq $rv) {
	next unless $pf & $rf & 2;
	push @p, $rp;
	last;
      }
      my $rr = $rf == 2 ? $pf : ($rf ^ 5);
      $rr &= 5 unless $pf & 2;
      # verscmp for spec and kiwi types
      my $vv;
      if ($binarytype eq 'deb') {
	$vv = Build::Deb::verscmp($pv, $rv, 1);
      } else {
	$vv = Build::Rpm::verscmp($pv, $rv, 1);
      }
      if ($rr & (1 << ($vv + 1))) {
	push @p, $rp;
	last;
      }
    }
  }
  @p = unify(@p) if @p > 1;
  return \@p;
}

sub expand;
*expand = \&Build::Expand::expand;


sub order {
  my ($config, @p) = @_;

  my $requires = $config->{'requiresh'};
  my $recommends = $config->{'recommendsh'};
  my $whatprovides = $config->{'whatprovidesh'};
  my %deps;
  my %rdeps;
  my %needed;
  my %p = map {$_ => 1} @p;
  for my $p (@p) {
    my @r;
    for my $r (@{$requires->{$p} || []}) {
      my @q = @{$whatprovides->{$r} || addproviders($config, $r)};
      push @r, grep {$_ ne $p && $p{$_}} @q;
    }
    if (%{$config->{'order'} || {}}) {
      push @r, grep {$_ ne $p && $config->{'order'}->{"$_:$p"}} @p;
    }
    @r = unify(@r);
    $deps{$p} = \@r;
    $needed{$p} = @r;
    push @{$rdeps{$_}}, $p for @r;
  }
  @p = sort {$needed{$a} <=> $needed{$b} || $a cmp $b} @p;
  my @good;
  my @res;
  # the big sort loop
  while (@p) {
    @good = grep {$needed{$_} == 0} @p;
    if (@good) {
      @p = grep {$needed{$_}} @p;
      push @res, @good;
      for my $p (@good) {
	$needed{$_}-- for @{$rdeps{$p}};
      }
      next;
    }
    # uh oh, cycle alert. find and remove all cycles.
    my %notdone = map {$_ => 1} @p;
    $notdone{$_} = 0 for @res;  # already did those
    my @todo = @p;
    while (@todo) {
      my $v = shift @todo;
      if (ref($v)) {
	$notdone{$$v} = 0;      # finished this one
	next;
      }
      my $s = $notdone{$v};
      next unless $s;
      my @e = grep {$notdone{$_}} @{$deps{$v}};
      if (!@e) {
	$notdone{$v} = 0;       # all deps done, mark as finished
	next;
      }
      if ($s == 1) {
	$notdone{$v} = 2;       # now under investigation
	unshift @todo, @e, \$v;
	next;
      }
      # reached visited package, found a cycle!
      my @cyc = ();
      my $cycv = $v;
      # go back till $v is reached again
      while(1) {
	die unless @todo;
	$v = shift @todo;
	next unless ref($v);
	$v = $$v;
	$notdone{$v} = 1 if $notdone{$v} == 2;
	unshift @cyc, $v;
	last if $v eq $cycv;
      }
      unshift @todo, $cycv;
      print STDERR "cycle: ".join(' -> ', @cyc)."\n";
      my $breakv;
      my @breakv = (@cyc, $cyc[0]);
      while (@breakv > 1) {
	last if $config->{'order'}->{"$breakv[0]:$breakv[1]"};
	shift @breakv;
      }
      if (@breakv > 1) {
	$breakv = $breakv[0];
      } else {
	$breakv = (sort {$needed{$a} <=> $needed{$b} || $a cmp $b} @cyc)[-1];
      }
      push @cyc, $cyc[0];	# make it loop
      shift @cyc while $cyc[0] ne $breakv;
      $v = $cyc[1];
      print STDERR "  breaking dependency $breakv -> $v\n";
      $deps{$breakv} = [ grep {$_ ne $v} @{$deps{$breakv}} ];
      $rdeps{$v} = [ grep {$_ ne $breakv} @{$rdeps{$v}} ];
      $needed{$breakv}--;
    }
  }
  return @res;
}

sub add_all_providers {
  my ($config, @p) = @_;
  my $whatprovides = $config->{'whatprovidesh'};
  my $requires = $config->{'requiresh'};
  my $recommends = $config->{'recommendsh'};
  my %a;
  for my $p (@p) {
    for my $r (@{$requires->{$p} || [$p]}) {
      my $rn = (split(' ', $r, 2))[0];
      $a{$_} = 1 for @{$whatprovides->{$rn} || []};
    }
  }
  push @p, keys %a;
  return unify(@p);
}

###########################################################################

sub recipe2buildtype {
  my ($recipe) = @_;
  return undef unless defined $recipe;
  return $1 if $recipe =~ /\.(spec|dsc|kiwi|livebuild)$/;
  $recipe =~ s/.*\///;
  $recipe =~ s/^_service:.*://;
  return 'arch' if $recipe eq 'PKGBUILD';
  return 'collax' if $recipe eq 'build.collax';
  return 'snapcraft' if $recipe eq 'snapcraft.yaml';
  return 'appimage' if $recipe eq 'appimage.yml';
  return 'docker' if $recipe eq 'Dockerfile';
  return 'fissile' if $recipe eq 'fissile.yml';
  return 'preinstallimage' if $recipe eq '_preinstallimage';
  return 'simpleimage' if $recipe eq 'simpleimage';
  return 'helm' if $recipe eq 'Chart.yaml';
  return 'flatpak' if $recipe =~ m/flatpak\.(?:ya?ml|json)$/;
  return 'dsc' if $recipe eq 'debian.control';
  return 'dsc' if $recipe eq 'control' && $_[0] =~ /(?:^|\/)debian\/[^\/]+$/s;
  return undef;
}

sub show {
  my ($conffile, $fn, $field, $arch) = @ARGV;
  my $cf = read_config($arch, $conffile);
  die unless $cf;
  my $d = Build::parse($cf, $fn);
  die("$d->{'error'}\n") if $d->{'error'};
  $d->{'sources'} = [ map {ref($d->{$_}) ? @{$d->{$_}} : $d->{$_}} grep {/^source/} sort keys %$d ];
  $d->{'patches'} = [ map {ref($d->{$_}) ? @{$d->{$_}} : $d->{$_}} grep {/^patch/} sort keys %$d ];
  my $x = $d->{$field};
  $x = [ $x ] unless ref $x;
  print "$_\n" for @$x;
}

sub parse_preinstallimage {
  return undef unless $do_rpm;
  my $d = Build::Rpm::parse(@_);
  $d->{'name'} ||= 'preinstallimage';
  return $d;
}

sub parse_simpleimage {
  return undef unless $do_rpm;
  my $d = Build::Rpm::parse(@_);
  $d->{'name'} ||= 'simpleimage';
  if (!defined($d->{'version'})) {
    my @s = stat($_[1]);
    $d->{'version'} = strftime "%Y.%m.%d-%H.%M.%S", gmtime($s[9] || time);
  }
  return $d;
}

sub parse {
  my ($cf, $fn, @args) = @_;
  return Build::Rpm::parse($cf, $fn, @args) if $do_rpm && $fn =~ /\.spec$/;
  return Build::Deb::parse($cf, $fn, @args) if $do_deb && $fn =~ /\.dsc$/;
  return Build::Kiwi::parse($cf, $fn, @args) if $do_kiwi && $fn =~ /config\.xml$/;
  return Build::Kiwi::parse($cf, $fn, @args) if $do_kiwi && $fn =~ /\.kiwi$/;
  return Build::LiveBuild::parse($cf, $fn, @args) if $do_livebuild && $fn =~ /\.livebuild$/;
  return parse_typed($cf, $fn, recipe2buildtype($fn), @args);
}

sub parse_typed {
  my ($cf, $fn, $buildtype, @args) = @_;
  $buildtype ||= '';
  return Build::Rpm::parse($cf, $fn, @args) if $do_rpm && $buildtype eq 'spec';
  return Build::Deb::parse($cf, $fn, @args) if $do_deb && $buildtype eq 'dsc';
  return Build::Kiwi::parse($cf, $fn, @args) if $do_kiwi && $buildtype eq 'kiwi';
  return Build::LiveBuild::parse($cf, $fn, @args) if $do_livebuild && $buildtype eq 'livebuild';
  return Build::Snapcraft::parse($cf, $fn, @args) if $do_snapcraft && $buildtype eq 'snapcraft';
  return Build::Appimage::parse($cf, $fn, @args) if $do_appimage && $buildtype eq 'appimage';
  return Build::Docker::parse($cf, $fn, @args) if $do_docker && $buildtype eq 'docker';
  return Build::Fissile::parse($cf, $fn, @args) if $do_fissile && $buildtype eq 'fissile';
  return parse_simpleimage($cf, $fn, @args) if $buildtype eq 'simpleimage';
  return Build::Arch::parse($cf, $fn, @args) if $do_arch && $buildtype eq 'arch';
  return Build::Collax::parse($cf, $fn, @args) if $do_collax && $buildtype eq 'collax';
  return parse_preinstallimage($cf, $fn, @args) if $buildtype eq 'preinstallimage';
  return Build::Helm::parse($cf, $fn, @args) if $buildtype eq 'helm';
  return Build::Flatpak::parse($cf, $fn, @args) if $buildtype eq 'flatpak';
  return undef;
}

sub query {
  my ($binname, %opts) = @_;
  my $handle = $binname;
  if (ref($binname) eq 'ARRAY') {
    $handle = $binname->[1];
    $binname = $binname->[0];
  }
  return Build::Rpm::query($handle, %opts) if $do_rpm && $binname =~ /\.d?rpm$/;
  return Build::Deb::query($handle, %opts) if $do_deb && $binname =~ /\.deb$/;
  return Build::Kiwi::queryiso($handle, %opts) if $do_kiwi && $binname =~ /\.iso$/;
  return Build::Arch::query($handle, %opts) if $do_arch && $binname =~ /\.pkg\.tar(?:\.gz|\.xz|\.zst)?$/;
  return Build::Arch::query($handle, %opts) if $do_arch && $binname =~ /\.arch$/;
  return undef;
}

sub showquery {
  my ($fn, $field) = @ARGV;
  my %opts;
  $opts{'evra'} = 1 if grep {$_ eq $field} qw{epoch version release arch buildid};
  $opts{'weakdeps'} = 1 if grep {$_ eq $field} qw{suggests enhances recommends supplements};
  $opts{'conflicts'} = 1 if grep {$_ eq $field} qw{conflicts obsoletes};
  $opts{'description'} = 1 if grep {$_ eq $field} qw{summary description};
  $opts{'filelist'} = 1 if $field eq 'filelist';
  $opts{'buildtime'} = 1 if grep {$_ eq $field} qw{buildtime buildid};
  my $d = Build::query($fn, %opts);
  die("cannot query $fn\n") unless $d;
  $d->{'buildid'} = getbuildid($d);
  my $x = $d->{$field};
  $x = [] unless defined $x;
  $x = [ $x ] unless ref $x;
  print "$_\n" for @$x;
}

sub queryhdrmd5 {
  my ($binname) = @_;
  return Build::Rpm::queryhdrmd5(@_) if $do_rpm && $binname =~ /\.d?rpm$/;
  return Build::Deb::queryhdrmd5(@_) if $do_deb && $binname =~ /\.deb$/;
  return Build::Kiwi::queryhdrmd5(@_) if $do_kiwi && $binname =~ /\.iso$/;
  return Build::Kiwi::queryhdrmd5(@_) if $do_kiwi && $binname =~ /\.raw$/;
  return Build::Kiwi::queryhdrmd5(@_) if $do_kiwi && $binname =~ /\.raw.install$/;
  return Build::Arch::queryhdrmd5(@_) if $do_arch && $binname =~ /\.pkg\.tar(?:\.gz|\.xz|\.zst)?$/;
  return Build::Arch::queryhdrmd5(@_) if $do_arch && $binname =~ /\.arch$/;
  return undef;
}

sub queryinstalled {
  my ($binarytype, @args) = @_;
  return Build::Rpm::queryinstalled(@args) if $binarytype eq 'rpm';
  return Build::Deb::queryinstalled(@args) if $binarytype eq 'deb';
  return Build::Arch::queryinstalled(@args) if $binarytype eq 'arch';
  return undef;
}

1;
