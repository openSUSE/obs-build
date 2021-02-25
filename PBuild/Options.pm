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

package PBuild::Options;

use strict;

my %known_options = (
  'h' => 'help',
  'help' => 'help',
  'preset' => 'preset:',
  'reponame' => 'reponame:',
  'nochecks' => 'nochecks',
  'no-checks' => 'nochecks',
  'arch' => 'arch:',
  'hostarch' => 'hostarch:',
  'host-arch' => 'hostarch:',
  'target' => 'target:',
  'jobs' => 'jobs:',
  'threads' => 'threads:',
  'buildjobs' => 'buildjobs:',
  'root' => 'root:',
  'dist' => 'dist::',
  'configdir' => 'configdir:',
  'repo' => 'repo::',
  'repository' => 'repo::',
  'registry' => 'registry::',
  'obs' => 'obs:',
  'result' => \&result_special,
  'result-pkg' => 'result-pkg::',
  'result-code' => 'result-code::',
  'details' => 'result-details',
  'xen' => \&vm_type_special,
  'kvm' => \&vm_type_special,
  'uml' => \&vm_type_special,
  'qemu' => \&vm_type_special,
  'emulator' => \&vm_type_special,
  'zvm' => \&vm_type_special,
  'lxc' => \&vm_type_special,
  'vm-type' => 'vm-type:',
  'vm-worker' => 'vm-worker:',
  'vm-worker-nr' => 'vm-worker-no:',
  'vm-worker-no' => 'vm-worker-no:',
  'vm-server' => 'vm-server:',
  'vm-region' => 'vm-server:',
  'vm-disk' => 'vm-disk:',
  'vm-swap' => 'vm-swap:',
  'swap' => 'vm-swap:',
  'vm-memory' => 'vm-memory:',
  'memory' => 'vm-memory:',
  'vm-kernel' => 'vm-kernel:',
  'vm-initrd' => 'vm-initrd:',
  'vm-disk-size' => 'vm-disk-size:',
  'vmdisk-rootsize' => 'vm-disk-size:',
  'vm-swap-size' => 'vm-swap-size:',
  'vmdisk-swapsize' => 'vm-swap-size:',
  'vm-disk-filesystem' => 'vm-disk-filesystem:',
  'vmdisk-filesystem' => 'vm-disk-filesystem:',
  'vm-disk-filesystem-options' => 'vm-disk-filesystem-options:',
  'vmdisk-filesystem-options' => 'vm-disk-filesystem-options:',
  'vm-disk-mount-options' => 'vm-disk-mount-options:',
  'vmdisk-mount-options' => 'vm-disk-mount-options:',
  'vm-disk-clean' => 'vm-disk-clean',
  'vmdisk-clean' => 'vm-disk-clean',
  'vm-hugetlbfs' => 'vm-hugetlbfs:',
  'hugetlbfs' => 'vm-hugetlbfs:',
  'vm-watchdog' => 'vm-watchdog',
  'vm-user' => 'vm-user:',
  'vm-enable-console' => 'vm-enable-console',
  'vm-telnet' => 'vm-telnet:',
  'vm-net' => 'vm-net::',
  'vm-netdev' => 'vm-netdev::',
  'vm-device' => 'vm-device::',
  'vm-custom-opt' => 'vm-custom-opt:',
  'vm-openstack-flavor' => 'vm-openstack-flavor:',
  'openstack-flavor' => 'vm-openstack-flavor:',
  'vm-emulator-script' => 'vm-emulator-script:',
  'emulator-script' => 'vm-emulator-script:',
);

sub getarg {
  my ($origopt, $args, $optional) = @_;
  return ${shift @$args} if @$args && ref($args->[0]);
  return shift @$args if @$args && $args->[0] !~ /^-/;
  die("Option $origopt needs an argument\n") unless $optional;
  return undef;
}

sub vm_type_special {
  my ($opts, $origopt, $opt, $args) = @_;
  my $arg;
  $arg = getarg($origopt, $args, 1) unless $opt eq 'zvm' || $opt eq 'lxc';
  $opts->{'vm-disk'} = $arg if defined $arg;
  $opts->{'vm-type'} = $opt;
}

my @codes = qw{broken succeeded failed unresolvable blocked scheduled waiting building excluded disabled locked};
my %known_codes = map {$_ => 1} @codes;

sub result_special {
  my ($opts, $origopt, $opt, $args) = @_;
  my $arg;
  $arg = getarg($origopt, $args, 1) if @$args && (ref($args->[0]) || $args->[0] !~ /\//);
  if (!defined($arg) || $arg eq 'all') {
    push @{$opts->{'result-code'}}, 'all';
    return;
  }
  if ($known_codes{$arg}) {
    push @{$opts->{'result-code'}}, $arg;
  } else {
    push @{$opts->{'result-pkg'}}, $arg;
  }
}

sub parse_options {
  my (@args) = @_;
  my %opts;
  my @back;
  while (@args) {
    my $opt = shift @args;
    if ($opt !~ /^-/) {
      push @back, $opt;
      next;
    }
    if ($opt eq '--') {
      push @back, @args;
      last;
    }
    my $origopt = $opt;
    $opt =~ s/^--?//;
    unshift @args, \"$1" if $opt =~ s/=(.*)$//;
    my $ko = $known_options{$opt};
    die("Unknown option '$origopt'. Exit.\n") unless $ko;
    if (ref($ko)) {
      $ko->(\%opts, $origopt, $opt, \@args);
    } elsif ($ko =~ s/(:.*)//) {
      my $arg = getarg($origopt, \@args);
      if ($1 eq '::') {
        push @{$opts{$ko}}, $arg;
      } else {
        $opts{$ko} = $arg;
      }
    } else {
      $opts{$ko} = 1;
    }
    die("Option $origopt does not take an argument\n") if @args && ref($args[0]);
  }
  return (\%opts, @back);
}

sub usage {
  my ($exitstatus) = @_;
  print <<'EOS';
Usage: pbuild [options] [dir]

Build all packages in the directory 'dir'.

Important options (see the man page for a full list):

  --dist known_dist|url|file
        distribution to build for
  --repo url
        repository to use, can be given multiple times
  --registry url
        registry to use, can be given multiple times
  --reponame name
        name of the destination dir
        defaults to "_build.<dist>.<arch>"
  --buildjobs number
        build in parallel with 'number' jobs
  --root rootdir
        do the build in the 'rootdir' directory
        defaults to '/var/tmp/build-root'
  --arch arch
        build for architecture 'arch'
        defaults to the host architecture
  --obs url
        open build service instance for obs:/ type urls
  --vm-*, --xen, --kvm, ...
	passed to the build tool, see the build(1) manpage

EOS
  exit($exitstatus) if defined $exitstatus;
}

1;
