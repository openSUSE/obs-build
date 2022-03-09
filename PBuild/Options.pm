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

use Build::Options;

use strict;

my $pbuild_options = {
  'h' => 'help',
  'help' => '',
  'preset' => ':',
  'list-presets' => '',
  'listpresets' => 'list-presets',
  'reponame' => ':',
  'noclean' => '',
  'no-clean' => 'noclean',
  'nochecks' => '',
  'no-checks' => 'nochecks',
  'arch' => ':',
  'hostarch' => ':',
  'host-arch' => 'hostarch:',
  'target' => ':',
  'jobs' => ':',
  'threads' => ':',
  'buildjobs' => ':',
  'root' => ':',
  'dist' => '::',
  'configdir' => ':',
  'repo' => '::',
  'repository' => 'repo::',
  'registry' => '::',
  'assets' => '::',
  'obs' => ':',
  'hostrepo' => '::',
  'hostrepository' => 'hostrepo::',
  'result' => \&result_rebuild_special,
  'result-pkg' => '::',
  'result-code' => '::',
  'details' => '',
  'terse' => '',
  'rebuild' => \&result_rebuild_special,
  'rebuild-pkg' => '::',
  'rebuild-code' => '::',
  'buildtrigger' => ':',
  'repoquery' => '::',
  'repoquery-host' => '::',
  'no-repo-refresh' => '',
  'xen' => \&vm_type_special,
  'kvm' => \&vm_type_special,
  'uml' => \&vm_type_special,
  'qemu' => \&vm_type_special,
  'emulator' => \&vm_type_special,
  'zvm' => \&vm_type_special,
  'lxc' => \&vm_type_special,
  'vm-type' => ':',
  'vm-worker' => ':',
  'vm-worker-no' => ':',
  'vm-worker-nr' => 'vm-worker-no:',
  'vm-server' => ':',
  'vm-region' => 'vm-server:',
  'vm-disk' => ':',
  'vm-swap' => ':',
  'swap' => 'vm-swap:',
  'vm-memory' => ':',
  'memory' => 'vm-memory:',
  'vm-kernel' => ':',
  'vm-initrd' => ':',
  'vm-disk-size' => ':',
  'vmdisk-rootsize' => 'vm-disk-size:',
  'vm-swap-size' => ':',
  'vmdisk-swapsize' => 'vm-swap-size:',
  'vm-disk-filesystem' => ':',
  'vmdisk-filesystem' => 'vm-disk-filesystem:',
  'vm-disk-filesystem-options' => ':',
  'vmdisk-filesystem-options' => 'vm-disk-filesystem-options:',
  'vm-disk-mount-options' => ':',
  'vmdisk-mount-options' => 'vm-disk-mount-options:',
  'vm-disk-clean' => '',
  'vmdisk-clean' => 'vm-disk-clean',
  'vm-hugetlbfs' => ':',
  'hugetlbfs' => 'vm-hugetlbfs:',
  'vm-watchdog' => '',
  'vm-user' => ':',
  'vm-enable-console' => '',
  'vm-telnet' => ':',
  'vm-net' => '::',
  'vm-network' => '',
  'vm-netdev' => '::',
  'vm-device' => '::',
  'vm-custom-opt' => ':',
  'vm-openstack-flavor' => ':',
  'openstack-flavor' => 'vm-openstack-flavor:',
  'vm-emulator-script' => ':',
  'debuginfo' => '',
  'debug' => 'debuginfo',
  'emulator-script' => 'vm-emulator-script:',
  'single' => ':',
  'single-flavor' => ':',
  'shell' => '',
  'shell-after-fail' => '',
  'no-timestamps' => '',
  'showlog' => '',
  'ccache' => \&ccache_special,
  'ccache-type' => '',
};

sub vm_type_special {
  my ($opts, $opt, $origopt, $args) = @_;
  my $arg;
  $arg = Build::Options::getarg($origopt, $args, 1) unless $opt eq 'zvm' || $opt eq 'lxc';
  $opts->{'vm-disk'} = $arg if defined $arg;
  $opts->{'vm-type'} = $opt;
}

sub ccache_special {
  my ($opts, $opt, $origopt, $args) = @_;
  my $arg;
  $arg = Build::Options::getarg($origopt, $args) if @$args && ref($args->[0]);
  $opts->{'ccache'} = 1;
  $opts->{'ccache-type'} = $arg if $arg;
}

my @codes = qw{broken succeeded failed unresolvable blocked scheduled waiting building excluded disabled locked};
my %known_codes = map {$_ => 1} @codes;

sub result_rebuild_special {
  my ($opts, $opt, $origopt, $args) = @_;
  my $arg;
  $arg = Build::Options::getarg($origopt, $args, 1) if @$args && (ref($args->[0]) || $args->[0] !~ /\//);
  if (!defined($arg) || $arg eq 'all') {
    push @{$opts->{"$opt-code"}}, 'all';
  } elsif ($known_codes{$arg}) {
    push @{$opts->{"$opt-code"}}, $arg;
  } else {
    push @{$opts->{"$opt-pkg"}}, $arg;
  }
}

sub parse_options {
  return Build::Options::parse_options($pbuild_options, @_);
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
  --preset name
        specify a preset defined in the project
  --list-presets
        list all known presets
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
  --result
        show the package build status

EOS
  exit($exitstatus) if defined $exitstatus;
}

sub merge_old_options {
  my ($opts, $oldopts) = @_;
  my $newopts = {};
  for (qw{preset dist repo hostrepo registry assets obs configdir root jobs threads buildjobs}) {
    $opts->{$_} = $oldopts->{$_} if !exists($opts->{$_}) && exists($oldopts->{$_});
    $newopts->{$_} = $opts->{$_} if exists($opts->{$_});
  }
  return $newopts;
}

1;
