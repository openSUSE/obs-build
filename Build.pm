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
use POSIX qw(strftime);
#use Data::Dumper;

our $expand_dbg;

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
  }
  $do_rpm = $do_deb = $do_kiwi = $do_arch = $do_collax = $do_livebuild = $do_snapcraft = $do_appimage = $do_docker = $do_fissile = 1 if !$do_rpm && !$do_deb && !$do_kiwi && !$do_arch && !$do_collax && !$do_livebuild && !$do_snapcraft && !$do_appimage && !$do_docker && !$do_fissile;

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
%define mips32  mips mipsel mipsr6 mipsr6el
%define mips64  mips64 mips64el mips64r6 mips64r6el
%define mipseb  mips mipsr6 mips64 mips64r6
%define mipsel  mipsel mipsr6el mips64el mips64r6el
%define mips    %{mips32} %{mips64}
%define sparc   sparc sparcv8 sparcv9 sparcv9v sparc64 sparc64v
%define alpha   alpha alphaev56 alphaev6 alphaev67
%define power64 ppc64 ppc64p7 ppc64le
};
my $extra_macros = '';

sub unify {
  my %h = map {$_ => 1} @_;
  return grep(delete($h{$_}), @_);
}

sub define {
  my ($def) = @_;
  $extra_macros .= "%define $def\n";
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

sub read_config_dist {
  my ($dist, $archpath, $configdir) = @_;

  my $arch = $archpath;
  $arch = 'noarch' unless defined $arch;
  $arch =~ s/:.*//;
  $arch = 'noarch' if $arch eq '';
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
  my $cf = read_config($arch, $dist);
  die("$dist: parse error\n") unless $cf;
  return $cf;
}

sub read_config {
  my ($arch, $cfile) = @_;
  my @macros = split("\n", $std_macros.$extra_macros);
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
    if ($l0 eq 'preinstall:' || $l0 eq 'vminstall:' || $l0 eq 'required:' || $l0 eq 'support:' || $l0 eq 'keep:' || $l0 eq 'prefer:' || $l0 eq 'ignore:' || $l0 eq 'conflict:' || $l0 eq 'runscripts:' || $l0 eq 'expandflags:' || $l0 eq 'buildflags:' || $l0 eq 'publishflags:') {
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
  for my $l (keys %{$config->{'substitute'}}) {
    $config->{'substitute_vers'}->{$l} = [ map {/^(.*?)(=)?$/g} unify(@{$config->{'substitute'}->{$l}}) ];
    $config->{'substitute'}->{$l} = [ unify(@{$config->{'substitute'}->{$l}}) ];
    s/=$// for @{$config->{'substitute'}->{$l}};
  }
  init_helper_hashes($config);
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

my %subst_defaults = (
  # defaults live-build package dependencies base on 4.0~a26 gathered with:
  # grep Check_package -r /usr/lib/live/build
  'build-packages:livebuild' => [
    'apt-utils', 'dctrl-tools', 'debconf', 'dosfstools', 'e2fsprogs', 'grub',
    'librsvg2-bin', 'live-boot', 'live-config', 'mtd-tools', 'parted',
    'squashfs-tools', 'syslinux', 'syslinux-common', 'wget', 'xorriso', 'zsync',
  ],
  'system-packages:livebuild' => [
    'apt-utils', 'cpio', 'dpkg-dev', 'live-build', 'lsb-release', 'tar',
  ],
  'system-packages:mock' => [
    'mock', 'createrepo',
  ],
  'system-packages:debootstrap' => [
    'debootstrap', 'lsb-release',
  ],
  'system-packages:kiwi-image' => [
    'kiwi', 'createrepo', 'tar',
  ],
  'system-packages:kiwi-product' => [
    'kiwi',
  ],
  'system-packages:docker' => [
    'docker',
  ],
  'system-packages:podman' => [
    'podman', 'buildah'
  ],
  'system-packages:fissile' => [
    'docker', # TODO: Add fissile here as soon as it is packaged
  ],
  'system-packages:deltarpm' => [
    'deltarpm',
  ],
);

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
  if (grep {$_ eq $buildtype} qw{livebuild docker kiwi fissile}) {
    push @deps, @{$config->{'substitute'}->{"build-packages:$buildtype"}
		  || $subst_defaults{"build-packages:$buildtype"} || []};
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
  push @deps, @{$config->{'preinstall'}};
  push @deps, @extra;
  @deps = grep {!$ndeps{"-$_"}} @deps;
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
  my ($in, $res, %options) = @_;

  my $nofiledeps = $options{'nofiledeps'};
  my $testcaseformat = $options{'testcaseformat'};
  if (ref($in)) {
    *F = $in;
  } else {
    open(F, '<', $in) || die("$in: $!\n");
  }
  $res ||= [];
  my $pkginfo = ref($res) eq 'HASH' ? $res : {};
  while (<F>) {
    my @s = split(' ', $_);
    my $s = shift @s;
    if ($s =~ /^I:(.*)\.(.*)-\d+\/\d+\/\d+:$/) {
      my $pkgid = $1;
      my $arch = $2; 
      my $evr = $s[0];
      $pkginfo->{$pkgid}->{'arch'} = $1 if $s[1] && $s[1] =~ s/-(.*)$//;
      $pkginfo->{$pkgid}->{'buildtime'} = $s[1] if $s[1];
      if ($evr =~ s/^\Q$pkgid-//) {
	$pkginfo->{$pkgid}->{'epoch'} = $1 if $evr =~ s/^(\d+)://;
	$pkginfo->{$pkgid}->{'release'} = $1 if $evr =~ s/-([^-]*)$//;
	$pkginfo->{$pkgid}->{'version'} = $evr;
      }
      next;
    }
    my @ss;
    while (@s) {
      if ($nofiledeps && $s[0] =~ /^\//) {
	shift @s;
	next;
      }
      if ($s[0] =~ /^rpmlib\(/) {
	splice(@s, 0, 3);
	next;
      }
      if ($s[0] =~ /^\(/) {
	push @ss, Build::Rpm::shiftrich(\@s);
	$ss[-1] = Build::Rpm::testcaseformat($ss[-1]) if $testcaseformat;
	next;
      }
      push @ss, shift @s;
      while (@s && $s[0] =~ /^[\(<=>|]/) {
	$ss[-1] .= " $s[0] $s[1]";
	$ss[-1] =~ s/ \((.*)\)/ $1/;
	$ss[-1] =~ s/(<|>){2}/$1/;
	splice(@s, 0, 2);
      }
    }
    my %ss;
    @ss = grep {!$ss{$_}++} @ss;	# unify
    if ($s =~ /^(P|R|C|O|r|s):(.*)\.(.*)-\d+\/\d+\/\d+:$/) {
      my $pkgid = $2;
      my $arch = $3;
      if ($1 eq "P") {
	$pkginfo->{$pkgid}->{'name'} = $pkgid;
	$pkginfo->{$pkgid}->{'arch'} = $arch;
	$pkginfo->{$pkgid}->{'provides'} = \@ss;
	next;
      }
      if ($1 eq "R") {
	$pkginfo->{$pkgid}->{'requires'} = \@ss;
	next;
      }
      if ($1 eq "C") {
	$pkginfo->{$pkgid}->{'conflicts'} = \@ss;
	next;
      }
      if ($1 eq "O") {
	$pkginfo->{$pkgid}->{'obsoletes'} = \@ss;
	next;
      }
      if ($1 eq "r") {
	$pkginfo->{$pkgid}->{'recommends'} = \@ss;
	next;
      }
      if ($1 eq "s") {
	$pkginfo->{$pkgid}->{'supplements'} = \@ss;
	next;
      }
    }
  }
  close F unless ref($in);

  # extract evr from self provides if there was no 'I' line
  for my $pkg (grep {!defined($_->{'version'})} values %$pkginfo) {
    my $n = $pkg->{'name'};
    next unless defined $n;
    my @sp = grep {/^\Q$n\E\s*=\s*/} @{$pkg->{'provides'} || []};
    next unless @sp;
    my $evr = $sp[-1];
    $evr =~ s/^\Q$n\E\s*=\s*//;
    $pkg->{'epoch'} = $1 if $evr =~ s/^(\d+)://;
    $pkg->{'release'} = $1 if $evr =~ s/-([^-]*)$//;
    $pkg->{'version'} = $evr;
  }

  if (ref($res) ne 'HASH') {
    for my $pkgid (sort keys %$pkginfo) {
      if (ref($res) eq 'CODE') {
	$res->($pkginfo->{$pkgid});
      } else {
	push @$res, $pkginfo->{$pkgid}
      }
    }
  }
  return $res;
}

sub readdeps {
  my ($config, $pkginfo, @depfiles) = @_;

  local *F;
  my %requires;
  my %provides;
  my %pkgconflicts;
  my %pkgobsoletes;
  my %recommends;
  my %supplements;
  my $nofiledeps = %{$config->{'fileprovides'} || {}} ? 0 : 1;
  $pkginfo ||= {};
  for my $depfile (@depfiles) {
    if (ref($depfile) eq 'HASH') {
      for my $rr (keys %$depfile) {
	$provides{$rr} = $depfile->{$rr}->{'provides'};
	$requires{$rr} = $depfile->{$rr}->{'requires'};
	$pkgconflicts{$rr} = $depfile->{$rr}->{'conflicts'};
	$pkgobsoletes{$rr} = $depfile->{$rr}->{'obsoletes'};
	$recommends{$rr} = $depfile->{$rr}->{'recommends'};
	$supplements{$rr} = $depfile->{$rr}->{'supplements'};
      }
      next;
    }
    parse_depfile($depfile, $pkginfo, 'nofiledeps' => $nofiledeps);
  }
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

sub getbuildid {
  my ($q) = @_;
  my $evr = $q->{'version'};
  $evr = "$q->{'epoch'}:$evr" if $q->{'epoch'};
  $evr .= "-$q->{'release'}" if defined $q->{'release'};;
  my $buildtime = $q->{'buildtime'} || 0;
  $evr .= " $buildtime";
  $evr .= "-$q->{'arch'}" if defined $q->{'arch'};
  return "$q->{'name'}-$evr";
}

sub writedeps {
  my ($fh, $pkg, $url) = @_;
  $url = '' unless defined $url;
  return unless defined($pkg->{'name'}) && defined($pkg->{'arch'});
  return if $pkg->{'arch'} eq 'src' || $pkg->{'arch'} eq 'nosrc';
  my $id = $pkg->{'id'};
  $id = ($pkg->{'buildtime'} || 0)."/".($pkg->{'filetime'} || 0)."/0" unless $id;
  $id = "$pkg->{'name'}.$pkg->{'arch'}-$id: ";
  print $fh "F:$id$url$pkg->{'location'}\n";
  print $fh "P:$id".join(' ', @{$pkg->{'provides'} || []})."\n";
  print $fh "R:$id".join(' ', @{$pkg->{'requires'}})."\n" if $pkg->{'requires'};
  print $fh "C:$id".join(' ', @{$pkg->{'conflicts'}})."\n" if $pkg->{'conflicts'};
  print $fh "O:$id".join(' ', @{$pkg->{'obsoletes'}})."\n" if $pkg->{'obsoletes'};
  print $fh "r:$id".join(' ', @{$pkg->{'recommends'}})."\n" if $pkg->{'recommends'};
  print $fh "s:$id".join(' ', @{$pkg->{'supplements'}})."\n" if $pkg->{'supplements'};
  print $fh "I:$id".getbuildid($pkg)."\n";
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

# XXX: should also check the package EVR
sub nevrmatch {
  my ($config, $r, @p) = @_;
  my $rn = $r;
  $rn =~ s/\s*([<=>]{1,2}).*$//;
  return grep {$_ eq $rn} @p;
}

# check if package $q has a conflict against an installed package.
# if yes, add message to @$eq and return true
sub checkconflicts {
  my ($config, $ins, $q, $eq, @r) = @_;
  my $whatprovides = $config->{'whatprovidesh'};
  my $ret = 0;
  for my $r (@r) {
    if ($r =~ /^\(.*\)$/) {
      # note the []: we ignore errors here. they will be reported if the package is chosen.
      my $n = normalizerich($config, $q, $r, 1, []);
      $ret = 1 if check_conddeps_notinst($q, $n, $eq, $ins);
      next;
    }
    my @eq = grep {$ins->{$_}} @{$whatprovides->{$r} || addproviders($config, $r)};
    next unless @eq;
    push @$eq, map {"(provider $q conflicts with $_)"} @eq;
    $ret = 1;
  }
  return $ret;
}

sub checkobsoletes {
  my ($config, $ins, $q, $eq, @r) = @_;
  my $whatprovides = $config->{'whatprovidesh'};
  my $ret = 0;
  for my $r (@r) {
    my @eq = grep {$ins->{$_}} nevrmatch($config, $r, @{$whatprovides->{$r} || addproviders($config, $r)});
    next unless @eq;
    push @$eq, map {"(provider $q obsoletes $_)"} @eq;
    $ret = 1;
  }
  return $ret;
}

sub todo2recommended {
  my ($config, $recommended, $todo) = @_;
  my $whatprovides = $config->{'whatprovidesh'};
  my $pkgrecommends = $config->{'recommendsh'} || {};
  for my $p (splice @$todo) {
    for my $r (@{$pkgrecommends->{$p} || []}) {
      $recommended->{$_} = 1 for @{$whatprovides->{$r} || addproviders($config, $r)}
    }
  }
}

sub cplx_mix {
  my ($q1, $q2, $todnf) = @_;
  my @q;
  for my $qq1 (@$q1) {
    for my $qq2 (@$q2) {
      my @qq = unify(sort(@$qq1, @$qq2));
      my %qq = map {$_ => 1} @qq;
      push @q, \@qq unless grep {$qq{"-$_"}} @qq;
    }
  }
  return $todnf ? 0 : 1 unless @q;
  return (-1, @q);
}

sub cplx_inv {
  my ($f, @q) = @_;
  return 1 - $f if $f == 0 || $f == 1;
  my @iq;
  for my $q (@q) {
    $q = [ map {"-$_"} @$q ];
    s/^--// for @$q;
  }
  return (-1, @q);
}

sub normalize_cplx_rec {
  my ($c, $r, $todnf) = @_;
  if ($r->[0] == 0) {
    my $ri = (split(/[ <=>]/, $r->[1], 2))[0];
    my ($config, $p, $ignore, $xignore) = @$c;
    if (!$todnf) {
      return 1 if $ignore->{$ri} || $xignore->{$ri};
      return 1 if defined($p) && ($ignore->{"$p:$ri"} || $xignore->{"$p:$ri"});
    }
    my $whatprovides = $config->{'whatprovidesh'};
    my @q = @{$whatprovides->{$r->[1]} || addproviders($config, $r->[1])};
    return 0 unless @q;
    if ($todnf) {
      return (-1, map { [ $_ ] } @q);
    } else {
      return (-1, [ @q ]);
    }
  }
  if ($r->[0] == 3 && @$r == 4) {
    # complex if/else case: A IF (B ELSE C) -> (A OR ~B) AND (C OR B)
    my ($n1, @q1) = normalize_cplx_rec($c, [3, $r->[1], $r->[2]], $todnf);
    my ($n2, @q2) = normalize_cplx_rec($c, [2, $r->[2], $r->[3]], $todnf);
    return 0 if $n1 == 0 || $n2 == 0;
    return ($n2, @q2) if $n1 == 1;
    return ($n1, @q1) if $n2 == 1;
    if (!$todnf) {
      return (-1, @q1, @q2);
    } else {
      return cplx_mix(\@q1, \@q2, $todnf);
    }
  }
  if ($r->[0] == 4 && @$r == 4) {
    # complex unless/else case: A UNLESS (B ELSE C) -> (A AND ~B) OR (C AND B)
    my ($n1, @q1) = normalize_cplx_rec($c, [4, $r->[1], $r->[2]], $todnf);
    my ($n2, @q2) = normalize_cplx_rec($c, [1, $r->[2], $r->[3]], $todnf);
    return 1 if $n1 == 1 || $n2 == 1;
    return ($n2, @q2) if $n1 == 0;
    return ($n1, @q1) if $n2 == 0;
    if ($todnf) {
      return (-1, @q1, @q2);
    } else {
      return cplx_mix(\@q1, \@q2, $todnf);
    }
  }
  if ($r->[0] == 1 || $r->[0] == 4) {
    # and / unless
    my $todnf2 = $r->[0] == 4 ? !$todnf : $todnf;
    my ($n1, @q1) = normalize_cplx_rec($c, $r->[1], $todnf);
    my ($n2, @q2) = normalize_cplx_rec($c, $r->[2], $todnf);
    ($n2, @q2) = cplx_inv($n2, @q2) if $r->[0] == 4;
    return 0 if $n1 == 0 || $n2 == 0;
    return ($n2, @q2) if $n1 == 1;
    return ($n1, @q1) if $n2 == 1;
    if (!$todnf) {
      return (-1, @q1, @q2);
    } else {
      return cplx_mix(\@q1, \@q2, $todnf);
    }
  }
  if ($r->[0] == 2 || $r->[0] == 3) {
    # or / if
    my $todnf2 = $r->[0] == 3 ? !$todnf : $todnf;
    my ($n1, @q1) = normalize_cplx_rec($c, $r->[1], $todnf);
    my ($n2, @q2) = normalize_cplx_rec($c, $r->[2], $todnf2);
    ($n2, @q2) = cplx_inv($n2, @q2) if $r->[0] == 3;
    return 1 if $n1 == 1 || $n2 == 1;
    return ($n2, @q2) if $n1 == 0;
    return ($n1, @q1) if $n2 == 0;
    if ($todnf) {
      return (-1, @q1, @q2);
    } else {
      return cplx_mix(\@q1, \@q2, $todnf);
    }
  }
  if ($r->[0] == 6 || $r->[0] == 7) {
    # with / without
    my ($n1, @q1) = normalize_cplx_rec($c, $r->[1], 0);
    my ($n2, @q2) = normalize_cplx_rec($c, $r->[2], 0);
    if ($n2 == 0 && $r->[0] == 7) {
      @q2 = ( [] );
      $n2 = -1;
    }
    return 0 if $n1 != -1 || $n2 != -1;
    return 0 if @q1 != 1 || @q2 != 1;
    @q1 = @{$q1[0]};
    @q2 = @{$q2[0]};
    return 0 if grep {/^-/} @q1;
    return 0 if grep {/^-/} @q2;
    my %q2 = map {$_ => 1} @q2;
    my @q;
    if ($r->[0] == 6) {
      @q = grep {$q2{$_}} @q1;
    } else {
      @q = grep {!$q2{$_}} @q1;
    }
    return 0 unless @q;
    if ($todnf) {
      return (-1, map { [ $_ ] } @q);
    } else {
      return (-1, [ @q ]);
    }
  }
  return 0;
}

sub normalizerich {
  my ($config, $p, $dep, $deptype, $error, $ignore, $xignore) = @_;
  my $r = Build::Rpm::parse_rich_dep($dep);
  if (!$r) {
    if (defined($p)) {
      push @$error, "cannot parse dependency $dep from $p";
    } else {
      push @$error, "cannot parse dependency $dep";
    }
    return [];
  }
  my $c = [$config, $p, $ignore || {}, $xignore || {}];
  my ($n, @q);
  if ($deptype == 0) {
    ($n, @q) = normalize_cplx_rec($c, $r);
    return () if $n == 1;
    if (!$n) {
      if (defined($p)) {
        push @$error, "nothing provides $dep needed by $p";
      } else {
        push @$error, "nothing provides $dep";
      }
      return [];
    }
  } else {
    ($n, @q) = normalize_cplx_rec($c, $r, 1);
    ($n, @q) = cplx_inv($n, @q);
    if (!$n) {
      if (defined($p)) {
        push @$error, "$p conflicts with always true $dep";
      } else {
        push @$error, "conflict with always true $dep";
      }
    }
  }
  for my $q (@q) {
    my @neg = @$q;
    @neg = grep {s/^-//} @neg;
    @neg = grep {$_ ne $p} @neg if defined $p;
    @$q = grep {!/^-/} @$q;
    $q = [$dep, $deptype, \@neg, @$q];
  }
  return \@q;
}

# handle a normalized rich dependency from install of package p
# todo_cond is undef if we are re-checking the cond queue
sub check_conddeps_inst {
  my ($p, $n, $error, $installed, $aconflicts, $todo, $todo_cond) = @_;
  for my $c (@$n) {
    my ($r, $rtype, $cond, @q) = @$c; 
    next unless defined $cond;			# already handled?
    next if grep {$installed->{$_}} @q;         # already fulfilled
    my @cx = grep {!$installed->{$_}} @$cond;   # open conditions
    if (!@cx) {
      $c->[2] = undef;				# mark as handled to avoid dups
      if (@q) {
        push @$todo, $c, $p;
      } elsif (@$cond) {
	if (defined($p)) {
	  push @$error, map {"$p conflicts with $_"} sort(@$cond);
	} else {
	  push @$error, map {"conflicts with $_"} sort(@$cond);
	}
      }    
    } else {
      if (!@q && @cx == 1) { 
	if (defined($p)) {
          $aconflicts->{$cx[0]} = "is in conflict with $p";
	} else {
          $aconflicts->{$cx[0]} = "is in conflict";
	}
      } elsif ($todo_cond) {
        push @{$todo_cond->{$_}}, [ $c, $p ] for @cx;
      }
    }
  }
}

# handle a normalized rich dependency from a not-yet installed package
# (we just check conflicts)
sub check_conddeps_notinst {
  my ($p, $n, $eq, $installed) = @_;
  my $ret = 0;
  for my $c (@$n) {
    my ($r, $rtype, $cond, @q) = @$c; 
    next if @q || !@$cond || grep {!$installed->{$_}} @$cond;
    push @$eq, map {"(provider $p conflicts with $_)"} sort(@$cond);
    $ret = 1;
  }
  return $ret;
}

sub expand {
  my ($config, @p) = @_;

  my $conflicts = $config->{'conflicth'};
  my $pkgconflicts = $config->{'pkgconflictsh'} || {};
  my $pkgobsoletes = $config->{'pkgobsoletesh'} || {};
  my $prefer = $config->{'preferh'};
  my $ignore = $config->{'ignoreh'};
  my $ignoreconflicts = $config->{'expandflags:ignoreconflicts'};
  my $ignoreignore;
  my $userecommendsforchoices = 1;

  my $whatprovides = $config->{'whatprovidesh'};
  my $requires = $config->{'requiresh'};

  my $xignore = { map {substr($_, 1) => 1} grep {/^-/} @p };
  $ignoreconflicts = 1 if $xignore->{'-ignoreconflicts--'};
  $ignore = {} if $xignore->{'-ignoreignore--'};
  if ($ignoreignore) {
    $xignore = {};
    $ignore = {};
  }
  my @directdepsend;
  if ($xignore->{'-directdepsend--'}) {
    delete $xignore->{'-directdepsend--'};
    @directdepsend = @p;
    for my $p (splice @p) {
      last if $p eq '--directdepsend--';
      push @p, $p;
    }
    @directdepsend = grep {!/^-/} splice(@directdepsend, @p + 1);
  }

  my %p;		# expanded packages
  my @todo;		# dependencies to install
  my @todo_inst;	# packages we decided to install
  my %todo_cond;
  my %recommended;	# recommended by installed packages
  my @rec_todo;		# installed todo
  my @error;
  my %aconflicts;	# packages we are conflicting with

  # handle direct conflicts
  for (grep {/^!/} @p) {
    my $r = /^!!/ ? substr($_, 2) : substr($_, 1);
    if ($r =~ /^\(.*\)$/) {
      my $n = normalizerich($config, undef, $r, 1, \@error);
      my %naconflicts;
      check_conddeps_inst(undef, $n, \@error, \%p, \%naconflicts, \@todo, \%todo_cond);
      push @{$aconflicts{$_}}, $naconflicts{$_} for keys %naconflicts;
      next;
    }
    my @q = @{$whatprovides->{$r} || addproviders($config, $r)};
    @q = nevrmatch($config, $r, @q) if /^!!/;
    push @{$aconflicts{$_}}, "is in conflict" for @q;
  }
  @p = grep {!/^[-!]/} @p;

  # add direct dependency packages. this is different from below,
  # because we add packages even if the dep is already provided and
  # we break ambiguities if the name is an exact match.
  for my $r (splice @p) {
    if ($r =~ /^\(.*\)$/) {
      push @p, $r;	# rich deps are never direct
      next;
    }
    my @q = @{$whatprovides->{$r} || addproviders($config, $r)};
    my $pn = $r;
    $pn =~ s/ .*//;
    @q = grep {$_ eq $pn} @q;
    if (@q != 1) {
      push @p, $r;
      next;
    }
    my $p = $q[0];
    print "added $p because of $r (direct dep)\n" if $expand_dbg;
    push @todo_inst, $p;
  }

  for my $r (@p, @directdepsend) {
    if ($r =~ /^\(.*\)$/) {
      # rich dep. normalize, put on todo.
      my $n = normalizerich($config, undef, $r, 0, \@error);
      my %naconflicts;
      check_conddeps_inst(undef, $n, \@error, \%p, \%naconflicts, \@todo, \%todo_cond);
      push @{$aconflicts{$_}}, $naconflicts{$_} for keys %naconflicts;
    } else {
      push @todo, $r, undef;
    }
  }

  for my $p (@todo_inst) {
    push @error, map {"$p $_"} @{$aconflicts{$p}} if $aconflicts{$p};
  }
  return (undef, @error) if @error;

  while (@todo || @todo_inst) {
    # install a set of chosen packages
    # ($aconficts must not be set for any of them)
    if (@todo_inst) {
      @todo_inst = unify(@todo_inst) if @todo_inst > 1;

      # check aconflicts (just in case)
      for my $p (@todo_inst) {
        push @error, map {"$p $_"} @{$aconflicts{$p}} if $aconflicts{$p};
      }
      return (undef, @error) if @error;

      # check against old cond dependencies. we do this step by step so we don't get dups.
      for my $p (@todo_inst) {
	$p{$p} = 1;
	if ($todo_cond{$p}) {
          for my $c (@{delete $todo_cond{$p}}) {
	    my %naconflicts;
	    check_conddeps_inst($c->[1], [ $c->[0] ], \@error, \%p, \%naconflicts, \@todo);
	    push @{$aconflicts{$_}}, $naconflicts{$_} for keys %naconflicts;
	  }
	}
        delete $aconflicts{$p};		# no longer needed
      }
      return undef, @error if @error;

      # now check our own dependencies
      for my $p (@todo_inst) {
	my %naconflicts;
	my %naobsoletes;
	$naconflicts{$_} = "is in conflict with $p" for @{$conflicts->{$p} || []};
	for my $r (@{$requires->{$p} || []}) {
	  if ($r =~ /^\(.*\)$/) {
	    my $n = normalizerich($config, $p, $r, 0, \@error, $ignore, $xignore);
	    check_conddeps_inst($p, $n, \@error, \%p, \%naconflicts, \@todo, \%todo_cond);
	    next;
	  }
	  my $ri = (split(/[ <=>]/, $r, 2))[0];
	  next if $ignore->{"$p:$ri"} || $xignore->{"$p:$ri"};
	  next if $ignore->{$ri} || $xignore->{$ri};
	  push @todo, ($r, $p);
	}
	if (!$ignoreconflicts) {
	  for my $r (@{$pkgconflicts->{$p}}) {
	    if ($r =~ /^\(.*\)$/) {
	      my $n = normalizerich($config, $p, $r, 1, \@error);
	      check_conddeps_inst($p, $n, \@error, \%p, \%naconflicts, \@todo, \%todo_cond);
	      next;
	    }
	    $naconflicts{$_} = "is in conflict with $p" for @{$whatprovides->{$r} || addproviders($config, $r)};
	  }
	  for my $r (@{$pkgobsoletes->{$p}}) {
	    $naobsoletes{$_} =  "is obsoleted by $p" for nevrmatch($config, $r, @{$whatprovides->{$r} || addproviders($config, $r)});
	  }
	}
	if (%naconflicts) {
	  push @error, map {"$p conflicts with $_"} grep {$_ ne $p && $p{$_}} sort keys %naconflicts;
	  push @{$aconflicts{$_}}, $naconflicts{$_} for keys %naconflicts;
	}
	if (%naobsoletes) {
	  push @error, map {"$p obsoletes $_"} grep {$_ ne $p && $p{$_}} sort keys %naobsoletes;
	  push @{$aconflicts{$_}}, $naobsoletes{$_} for keys %naobsoletes;
	}
	push @rec_todo, $p if $userecommendsforchoices;
      }
      return undef, @error if @error;
      @todo_inst = ();
    }
 
    for my $pass (0, 1, 2, 3, 4, 5) {
      my @todo_next;
      while (@todo) {
	my ($r, $p) = splice(@todo, 0, 2);
	my $rtodo = $r;
	my @q;
	if (ref($r)) {
	  ($r, undef, undef, @q) = @$r;
	} else {
	  @q = @{$whatprovides->{$r} || addproviders($config, $r)};
	}
	next if grep {$p{$_}} @q;
	my $pp = defined($p) ? "$p:" : '';
	my $pn = defined($p) ? " needed by $p" : '';
	if (defined($p) && !$ignoreignore) {
	  next if grep {$ignore->{$_} || $xignore->{$_}} @q;
	  next if grep {$ignore->{"$pp$_"} || $xignore->{"$pp$_"}} @q;
	}

	if (!@q) {
	  next if $r =~ /^\// && defined($p);
	  push @error, "nothing provides $r$pn";
	  next;
	}

	if (@q > 1 && $pass == 0) {
	  push @todo_next, $rtodo, $p;
	  next;
	}

	# pass 0: only one provider
	# pass 1: conflict pruning
        my $nq = @q;
	my @eq;
	for my $q (@q) {
	  push @eq, map {"(provider $q $_)"} @{$aconflicts{$q}} if $aconflicts{$q};
	}
	@q = grep {!$aconflicts{$_}} @q;
	if (!$ignoreconflicts) {
	  for my $q (splice @q) {
	    push @q, $q unless @{$pkgconflicts->{$q} || []} && checkconflicts($config, \%p, $q, \@eq, @{$pkgconflicts->{$q}});
	  }
	  for my $q (splice @q) {
	    push @q, $q unless @{$pkgobsoletes->{$q} || []} && checkobsoletes($config, \%p, $q, \@eq, @{$pkgobsoletes->{$q}});
	  }
	}

	if (!@q) {
	  push @error, "conflict for providers of $r$pn", sort(@eq);
	  next;
	}
        if (@q == 1) {
	  push @todo_inst, $q[0];
	  print "added $q[0] because of $pp$r\n" if $expand_dbg;
          next;
        }

	# pass 2: prune neg prefers and simple pos prefers
        if ($pass < 2) {
	  print "undecided about $pp$r: @q\n" if $expand_dbg;
	  push @todo_next, $rtodo, $p;
	  next;
        }
	if (@q > 1) {
	  my @pq = grep {!$prefer->{"-$_"} && !$prefer->{"-$pp$_"}} @q;
	  @q = @pq if @pq;
	  @pq = grep {$prefer->{$_} || $prefer->{"$pp$_"}} @q;
	  @q = @pq if @pq == 1;
	}
        if (@q == 1) {
	  push @todo_inst, $q[0];
	  print "added $q[0] because of $pp$r\n" if $expand_dbg;
          next;
        }

	# pass 3: prune pos prefers and debian choice deps
        if ($pass < 3) {
	  push @todo_next, $rtodo, $p;
	  next;
        }
	if (@q > 1) {
	  my @pq = grep {$prefer->{$_} || $prefer->{"$pp$_"}} @q;
	  if (@pq > 1) {
	    my %pq = map {$_ => 1} @pq;
	    @q = (grep {$pq{$_}} @{$config->{'prefer'}})[0];
	  } elsif (@pq == 1) {
	    @q = @pq;
	  }
        }
	if (@q > 1 && $r =~ /\|/) {
	  # choice op, implicit prefer of first match...
	  my %pq = map {$_ => 1} @q;
	  for my $rr (split(/\s*\|\s*/, $r)) {
	    next unless $whatprovides->{$rr};
	    my @pq = grep {$pq{$_}} @{$whatprovides->{$rr}};
	      next unless @pq;
	      @q = @pq;
	      last;
	  }
	}
        if (@q == 1) {
	  push @todo_inst, $q[0];
	  print "added $q[0] because of $pp$r\n" if $expand_dbg;
          next;
        }

	# pass 4: prune recommends
        if ($pass < 4) {
	  push @todo_next, $rtodo, $p;
	  next;
        }
	todo2recommended($config, \%recommended, \@rec_todo) if @rec_todo;
	my @pq = grep {$recommended{$_}} @q;
	print "recommended [@pq] among [@q]\n" if $expand_dbg;
	@q = @pq if @pq;
        if (@q == 1) {
	  push @todo_inst, $q[0];
	  print "added $q[0] because of $pp$r\n" if $expand_dbg;
          next;
        }

        # pass 5: record error
        if ($pass < 5) {
	  push @todo_next, $rtodo, $p;
	  next;
        }
	@q = sort(@q);
	if (defined($p)) {
	  push @error, "have choice for $r needed by $p: @q";
	} else {
	  push @error, "have choice for $r: @q";
	}
      }
      @todo = @todo_next;
      last if @todo_inst;
    }
    return undef, @error if @error;
  }

  return 1, (sort keys %p);
}

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
  my $fnx = $fn;
  $fnx =~ s/.*\///;
  $fnx =~ s/^[0-9a-f]{32,}-//;	# hack for OBS srcrep implementation
  $fnx =~ s/^_service:.*://;
  return parse_simpleimage($cf, $fn, @args) if $fnx eq 'simpleimage';
  return Build::Snapcraft::parse($cf, $fn, @args) if $do_snapcraft && $fnx eq 'snapcraft.yaml';
  return Build::Appimage::parse($cf, $fn, @args) if $do_appimage && $fnx eq 'appimage.yml';
  return Build::Docker::parse($cf, $fn, @args) if $do_docker && $fnx eq 'Dockerfile';
  return Build::Fissile::parse($cf, $fn, @args) if $do_fissile && $fnx eq 'fissile.yml';
  return Build::Arch::parse($cf, $fn, @args) if $do_arch && $fnx eq 'PKGBUILD';
  return Build::Collax::parse($cf, $fn, @args) if $do_collax && $fnx eq 'build.collax';
  return parse_preinstallimage($cf, $fn, @args) if $fnx eq '_preinstallimage';
  return undef;
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
