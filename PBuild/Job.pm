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

package PBuild::Job;

use strict;

use Time::HiRes ();

use PBuild::Util;
use PBuild::Cando;
use PBuild::Verify;
use PBuild::RepoMgr;

#
# Fork and exec the build tool
#
sub forkjob {
  my ($opts, $args, $stderrfile) = @_;
  if (!$opts->{'shell'}) {
    my $pid = PBuild::Util::xfork();
    return $pid if $pid;
    if (!$opts->{'showlog'}) {
      open(STDIN, '<', '/dev/null');
      open(STDOUT, '>', '/dev/null');
      if ($stderrfile) {
        open(STDERR, '>', $stderrfile) || die("$stderrfile: $!\n");
      } else {
        open(STDERR, '>&STDOUT');
      }
    }
  }
  exec(@$args);
  die("$args->[0]: $!\n");
}

#
# Update the logfile_lines element by counting lines in the logfile
#
sub updatelines {
  my ($job) = @_;
  my $logfile = $job->{'logfile'};
  return unless $logfile;
  my @s = stat($logfile);
  my $newsize = @s ? $s[7] : 0;
  my $oldsize = $job->{'logfile_oldsize'} || 0;
  return if $oldsize < 0 || $newsize <= $oldsize;
  my $fd;
  if (open($fd, '<', $logfile)) {
    sysseek($fd, $oldsize, 0);
    while ($oldsize < $newsize) {
      my $b = '';
      my $r = sysread($fd, $b, $newsize - $oldsize > 8192 ? 8192 : $newsize - $oldsize);
      last if $r < 0;
      $oldsize += $r;
      $job->{'logfile_lines'} += $b =~ tr/\n/\n/;
    }
    close $fd;
  } else {
    $oldsize = -1;
  }
  $job->{'logfile_oldsize'} = $oldsize;
}

#
# Wait for one or more build jobs to finish
#
sub waitjob {
  my ($opts, @jobs) = @_;
  local $| = 1;
  my $oldmsg;
  while (1) {
    Time::HiRes::sleep(.2);
    my $msg = '[';
    for my $job (@jobs) {
      updatelines($job);
      if (($job->{'nbuilders'} || 1) > 1) {
        $msg .= " $job->{'name'}:$job->{'logfile_lines'}";
      } else {
        $msg .= " $job->{'logfile_lines'}";
      }
      my $r = waitpid($job->{'pid'}, POSIX::WNOHANG);
      next unless $r && $r == $job->{'pid'};
      my $waitstatus = $?;
      $waitstatus = $waitstatus & 255 ? -1 : $waitstatus >> 8;
      $job->{'waitstatus'} = $waitstatus;
      $job->{'endtime'} = time();
      delete $job->{'pid'};
      print "\n" if $oldmsg;
      return $job;
    }
    $msg .= ' ]';
    print "\r$msg" if !$opts->{'showlog'} && (!$oldmsg || $oldmsg ne $msg);
    $oldmsg = $msg;
  }
}

#
# Search for build artifacts
#
sub collect_result {
  my ($p, $buildroot) = @_;
  my @d;
  push @d, map {"RPMS/$_"} sort(PBuild::Util::ls("$buildroot/.build.packages/RPMS"));
  push @d, 'SRPMS';
  @d = ('DEBS') if $p->{'recipe'} =~ /(?:\.dsc|build\.collax)$/ || $p->{'recipe'} eq 'debian/control' || $p->{'recipe'} eq 'debian.control';
  if (-d "$buildroot/.build.packages/SDEBS") {
    @d = map {"DEBS/$_"} sort(PBuild::Util::ls("$buildroot/.build.packages/DEBS"));   # assume debbuild
    push @d, 'SDEBS';
  }
  @d = ('ARCHPKGS') if $p->{'recipe'} =~ /PKGBUILD$/;
  @d = ('KIWI') if $p->{'recipe'} =~ /\.kiwi$/;
  @d = ('DOCKER') if $p->{'recipe'} =~ /Dockerfile(\.|$)/;
  @d = ('FISSILE') if $p->{'recipe'} =~ /fissile\.yml$/;
  @d = ('HELM') if $p->{'recipe'} =~ /Chart\.yaml$/;
  @d = ('PRODUCT') if $p->{'recipe'} =~ /\.productcompose$/;
  push @d, 'OTHER';
  my @send;
  for my $d ('.', @d) {
    my @files = sort(PBuild::Util::ls("$buildroot/.build.packages/$d"));
    @files = grep {$_ ne 'same_result_marker' && $_ ne '.kiwitree'} @files;
    if ($p->{'buildtype'} eq 'productcompose' && $d eq 'PRODUCT') {
      @files = grep {! -l "$buildroot/.build.packages/$d/$_" && (-d _ || -f _)} @files;
    } else {
      @files = grep {! -l "$buildroot/.build.packages/$d/$_" && -f _} @files;
    }
    push @send, map {"$buildroot/.build.packages/$d/$_"} @files;
  }
  my %send = map {(split('/', $_))[-1] => $_} @send;
  for my $f (sort keys %send) {
    if ($f =~ /^\./) {
      delete $send{$f};
      next;
    }
    if ($f =~ /^_/) {
      next if $f eq '_statistics';
      next if $f eq '_ccache.tar';
      delete $send{$f};
      next;
    }
  }
  delete $send{'_log'};
  return \%send;
}

#
# Copy the package sources into the build root
#
sub copy_sources {
  my ($p, $srcdir) = @_;
  # for kiwi/docker we need to copy the sources to $buildroot/.build-srcdir
  # so that we can set up the "repos" and "containers" directories
  PBuild::Util::rm_rf($srcdir);
  PBuild::Util::mkdir_p($srcdir);
  for (sort keys %{$p->{'files'}}) {
    if (/(.*)\/$/) {
      PBuild::Util::cp_a("$p->{'dir'}/$1", "$srcdir/$1");
    } else {
      PBuild::Util::cp("$p->{'dir'}/$_", "$srcdir/$_");
    }
  }
}

#
# Export upstream tarballs for git-buildpackage
#
sub export_origtar {
  my ($p, $srcdir, $opts) = @_;
  return unless -d "$p->{'dir'}/.git";
  system("$opts->{'libbuild'}/export_debian_orig_from_git", $p->{'dir'}, "$srcdir/build.origtar") && die("export_orig_from_git $p->{'dir'} $srcdir/build.origtar: $?\n");
}

#
# Find which package is providing the base container in a container build
#
sub findbasecontainer {
  my ($ctx, $p, $bdeps) = @_;
  my $cname = (grep {/^container:/} @{$p->{'dep'} || []})[-1];
  return undef unless $cname;
  my $bconf = $ctx->{'bconf'};
  my %providers = map {$_ => 1} @{$bconf->{'whatprovidesh'}->{$cname} || []};
  return (grep {$providers{$_}} @{$bdeps || []})[0];
}

#
# Create a new build job
#
# ctx usage: opts hostarch bconf arch repos dep2pkg buildconfig debuginfo
#
sub createjob {
  my ($ctx, $jobname, $nbuilders, $buildroot, $p, $bdeps, $pdeps, $vmdeps, $sysdeps, $tdeps, $jobopts) = @_;
  my $opts = { %{$ctx->{'opts'}} };	# create copy so we can modify
  my $hostarch = $opts->{'hostarch'};
  my $arch = $p->{'native'} ? $hostarch : $ctx->{'arch'};

  my $bconf = $ctx->{'bconf'};
  my $helperarch = $bconf->{'hostarch'} || $arch;
  die("don't know how to build arch $helperarch\n") unless $PBuild::Cando::knownarch{$helperarch};

  my $helper = '';
  /^\Q$helperarch\E:(.*)$/ && ($helper = $1) for @{$PBuild::Cando::cando{$hostarch}};

  my %runscripts = map {$_ => 1} Build::get_runscripts($bconf);
  my %bdeps = map {$_ => 1} @$bdeps;
  my %pdeps = map {$_ => 1} @$pdeps;
  my %vmdeps = map {$_ => 1} @$vmdeps;
  my %sysdeps = map {$_ => 1} @$sysdeps;

  my @alldeps;
  my $kiwimode = $p->{'buildtype'} eq 'kiwi' || $p->{'buildtype'} eq 'docker' || $p->{'buildtype'} eq 'fissile' || $p->{'buildtype'} eq 'productcompose' ? $p->{'buildtype'} : undef;
  if ($kiwimode) {
    @alldeps = PBuild::Util::unify(@$pdeps, @$vmdeps, @$sysdeps);
  } elsif ($p->{'buildtype'} eq 'mkosi') {
    @alldeps = PBuild::Util::unify(@$pdeps, @$vmdeps, grep {!/^mkosi:/} @$bdeps, @$sysdeps);
  } else {
    @alldeps = PBuild::Util::unify(@$pdeps, @$vmdeps, @$bdeps, @$sysdeps);
  }
  my @rpmlist;
  my $binlocations = $ctx->{'repomgr'}->getbinarylocations($ctx->dep2bins_host(@alldeps));
  for my $bin (@alldeps) {
    push @rpmlist, "$bin $binlocations->{$bin}";
  }
  if (@{$tdeps || []}) {
    $binlocations = $ctx->{'repomgr'}->getbinarylocations($ctx->dep2bins(@$tdeps));
    for my $bin (@$tdeps) {
      push @rpmlist, "sysroot: $bin $binlocations->{$bin}";
    }
  }
  push @rpmlist, "preinstall: ".join(' ', @$pdeps);
  push @rpmlist, "vminstall: ".join(' ', @$vmdeps);
  push @rpmlist, "runscripts: ".join(' ', grep {$runscripts{$_}} (@$pdeps, @$vmdeps));
  if (@$sysdeps && !$kiwimode) {
    push @rpmlist, "noinstall: ".join(' ', grep {!($sysdeps{$_} || $vmdeps{$_} || $pdeps{$_})} @$bdeps);
    push @rpmlist, "installonly: ".join(' ', grep {!$bdeps{$_}} @$sysdeps);
  }
  PBuild::Util::mkdir_p($buildroot);
  PBuild::Util::writestr("$buildroot/.build.rpmlist", undef, join("\n", @rpmlist)."\n");
  PBuild::Util::writestr("$buildroot/.build.config", undef, $ctx->{'buildconfig'});

  my $needsbinariesforbuild;
  my $needobspackage;
  my $needsslcert;
  my $needappxsslcert;
  if ($p->{'buildtype'} ne 'kiwi') {
    my $fd;
    if (open($fd, '<', "$p->{'dir'}/$p->{'recipe'}")) {
      while(<$fd>) {
	chomp;
	$needsbinariesforbuild = 1 if /^#\s*needsbinariesforbuild\s*$/s;
	$needobspackage = 1 if /\@OBS_PACKAGE\@/;
	$needsslcert = 1 if /^(?:#|Obs:)\s*needsslcertforbuild\s*$/s;
	$needappxsslcert = 1 if /^(?:#|Obs:)\s*needsappxsslcertforbuild\s*$/s;
      }
      close($fd);
    }
  }

  my $srcdir = $p->{'dir'};
  my $copy_sources_asis;
  # for kiwi/docker we need to copy the sources to $buildroot/.build-srcdir
  # so that we can set up the "repos" and "containers" directories
  if ($kiwimode || $p->{'buildtype'} eq 'mkosi' || $p->{'asset_files'} || grep {/\/$/} keys %{$p->{'files'} || {}}) {
    $srcdir = "$buildroot/.build-srcdir";
    copy_sources($p, $srcdir);
    $ctx->{'assetmgr'}->copy_assets($p, $srcdir) if $p->{'asset_files'};
    export_origtar($p, $srcdir, $opts) if $p->{'recipe'} eq 'debian/control';
    $copy_sources_asis = 1;
  }

  my $oldresultdir = "$ctx->{'builddir'}/$p->{'pkg'}";

  my @args;
  push @args, $helper if $helper;
  push @args, "$opts->{'libbuild'}/build";
  my $vm = $opts->{'vm-type'} || '';
  if ($vm =~ /(xen|kvm|zvm|emulator|pvm|qemu)/) {
    # allow setting the filesystem type with the build config
    $opts->{'vm-disk-filesystem'} ||= $bconf->{'buildflags:vmfstype'} if $bconf->{'buildflags:vmfstype'};
    $opts->{'vm-disk-filesystem-options'} ||= $bconf->{'buildflags:vmfsoptions'} if $bconf->{'buildflags:vmfsoptions'};
    mkdir("$buildroot/.mount") unless -d "$buildroot/.mount";
    push @args, "--root=$buildroot/.mount";
    for my $opt (qw{vm-type vm-disk vm-swap vm-emulator-script vm-memory vm-kernel vm-initrd vm-custom-opt vm-disk-size vm-swap-size vm-disk-filesystem vm-disk-filesystem-options vm-disk-mount-options vm-disk-clean vm-hugetlbfs vm-worker vm-worker-no vm-enable-console vm-net vm-netdev vm-device vm-network}) {
      next unless defined $opts->{$opt};
      if ($opt eq 'vm-disk-clean' || $opt eq 'vm-enable-console') {
	push @args, "--$opt",
      } elsif (ref($opts->{$opt})) {
        push @args, map {"--$opt=$_"} @{$opts->{$opt}};
      } else {
        push @args, "--$opt=$opts->{$opt}";
      }
    }
    push @args, '--statistics';
    push @args, '--vm-watchdog' unless $opts->{'shell'};
  } elsif ($vm eq 'openstack') {
    mkdir("$buildroot/.mount") unless -d "$buildroot/.mount";
    push @args, "--root=$buildroot/.mount";
    for my $opt (qw{vm-type vm-disk vm-swap vm-server vm-worker vm-kernel vm-openstack-flavor}) {
      push @args, "--$opt=$opts->{$opt}" if defined $opts->{$opt},
    }
  } elsif ($vm eq 'lxc' || $vm eq 'docker') {
    push @args, "--root=$buildroot";
    for my $opt (qw{vm-type vm-memory}) {
      push @args, "--$opt=$opts->{$opt}" if defined $opts->{$opt},
    }
  } else {
    push @args, "--root=$buildroot";
    push @args, "--vm-type=$vm" if $vm; 
  }

  push @args, '--clean' unless $opts->{'noclean'};
  push @args, '--checks' if $opts->{'checks'};
  push @args, '--nochecks' if $opts->{'nochecks'};
  push @args, '--shell' if $opts->{'shell'};
  push @args, '--shell-after-fail' if $opts->{'shell-after-fail'};
  push @args, '--no-timestamps' if $opts->{'no-timestamps'};
  push @args, '--skip-bundle';
  push @args, '--changelog' unless $opts->{'nochangelog'};
  #push @args, '--oldpackages', $oldresultdir if -d $oldresultdir;
  push @args, '--ccache' if $jobopts->{'ccache'};
  push @args, '--ccache-create-archive' if $jobopts->{'ccache'};
  push @args, '--ccache-type', $jobopts->{'ccache-type'} if $jobopts->{'ccache'} && $jobopts->{'ccache-type'};
  if ($jobopts->{'ccache'} && -s "$oldresultdir/_ccache.tar") {
    PBuild::Util::mkdir_p("$buildroot/.build.oldpackages");
    PBuild::Util::cp("$oldresultdir/_ccache.tar", "$buildroot/.build.oldpackages/_ccache.tar");
    push @args, "--ccache-archive", "$buildroot/.build.oldpackages/_ccache.tar";
  }
  push @args, '--dist', "$buildroot/.build.config";
  push @args, '--rpmlist', "$buildroot/.build.rpmlist";
  push @args, '--logfile', "$buildroot/.build.log";
  push @args, '--baselibs' if $opts->{'baselibs'};
  push @args, '--debuginfo' if $ctx->{'debuginfo'} || $opts->{'debuginfo'};
  push @args, "--arch=$arch";
  push @args, '--jobs', $opts->{'jobs'} if $opts->{'jobs'};
  push @args, '--release', $opts->{'release'} if $opts->{'release'};
  push @args, '--threads', $opts->{'threads'} if $opts->{'threads'};
  push @args, "--buildflavor=$p->{'flavor'}" if $p->{'flavor'};
  push @args, "--obspackage=".($p->{'originpackage'} || $p->{'pkg'}) if $needobspackage;
  push @args, "--copy-sources-asis" if $copy_sources_asis;
  push @args, "--rpm-recipe-in-subdir" if $p->{'recipe'} =~ /^(?:package|dist)\/.*\.spec$/;
  push @args, "$srcdir/$p->{'recipe'}";

  if ($kiwimode || $p->{'buildtype'} eq 'mkosi') {
    # now setup the repos/containers directories
    $ctx->{'repomgr'}->copyimagebinaries($ctx->dep2bins(@$bdeps), $srcdir);
    my $basecontainer = findbasecontainer($ctx, $p, $bdeps);
    $ctx->{'repomgr'}->writecontainerannotation($ctx->dep2bins($basecontainer)->[0], $srcdir) if $basecontainer;
    # and tell kiwi how to use them
    if ($p->{'buildtype'} eq 'kiwi') {
      my @kiwiargs;
      push @kiwiargs, '--ignore-repos';
      push @kiwiargs, '--add-repo', 'dir://./repos/pbuild/pbuild';
      push @kiwiargs, '--add-repotype', 'rpm-md';
      push @kiwiargs, '--add-repoprio', '1';
      if (-d "$srcdir/containers") {
	for my $containerfile (grep {/\.tar$/} sort(PBuild::Util::ls("$srcdir/containers")))  {
	  push @kiwiargs, "--set-container-derived-from=dir://./containers/$containerfile";
	}
      }
      push @args, map {"--kiwi-parameter=$_"} @kiwiargs;
    }
  }

  unlink("$buildroot/.build.log");
  #print "building $p->{'pkg'}/$p->{'recipe'}\n";

  my $pid = forkjob($opts, \@args, "$buildroot/.build.log");
  return { 'name' => $jobname, 'nbuilders' => $nbuilders, 'pid' => $pid, 'buildroot' => $buildroot, 'vm_type' => $vm, 'pdata' => $p, 'logfile' => "$buildroot/.build.log", 'logfile_lines' => 0, 'starttime' => time() };
}

#
# Move the build result into the correct place if we used a
# subdirectory for building
#
sub rename_build_result {
  my ($vm, $buildroot) = @_;
  return unless $vm =~ /(xen|kvm|zvm|emulator|pvm|qemu|openstack)/;
  # get rid of old results
  unlink("$buildroot/.build.packages");
  if (-d "$buildroot/.build.packages") {
    PBuild::Util::cleandir("$buildroot/.build.packages");
    rmdir("$buildroot/.build.packages");
  }
  rename("$buildroot/.mount/.build.packages", "$buildroot/.build.packages") || die("final rename failed: $!\n");
}

#
# Return the last lines of a logfile
#
sub get_last_lines {
  my ($logfile) = @_;
  my $fd;
  open($fd, '<', $logfile) || return '';  
  if (-s $fd > 8192) {
    defined(sysseek($fd, -8192, 2)) || return '';
  }
  my $buf = '';
  sysread($fd, $buf, 8192);
  close $fd;
  my @buf = split(/\r?\n/, $buf);
  shift @buf if length($buf) == 8192 && @buf > 1;
  @buf = splice(@buf, -5) if @buf > 5;
  return @buf ? join("\n", @buf)."\n" : '';
}

#
# Finalize a build job after the build process has finished
#
sub finishjob {
  my ($job) = @_;

  die("job is still building\n") if $job->{'pid'};
  my $buildroot = $job->{'buildroot'};
  my $vm = $job->{'vm_type'};
  my $p = $job->{'pdata'};
  my $ret = $job->{'waitstatus'};
  die("waitstatus not set\n") unless defined $ret;
  $ret = 1 if $ret < 0;

  # 1: build failure
  # 2: unchanged build
  # 3: badhost
  # 4: fatal build error
  # 9: genbuildreqs
  if ($ret == 4) {
    my $ll = get_last_lines("$buildroot/.build.log");
    print $ll if $ll;
    die("fatal build error, see $buildroot/.build.log for more information\n");
  }
  if ($ret == 3) {
    $ret = 1;
  }
  if ($ret == 9) {
    rename_build_result($vm, $buildroot);
    die("XXX: dynamic buildreqs not implemented yet");
  }
  
  if (!$ret && (-l "$buildroot/.build.log" || ! -s _)) {
    unlink("$buildroot/.build.log");
    PBuild::Util::writestr("$buildroot/.build.log", undef, "build created no logfile!\n");
    $ret = 1;
  }
  if ($ret) {
    my $result = { '_log' => "$buildroot/.build.log" };
    return ('failed', $result);
  }
  rename_build_result($vm, $buildroot);
  my $result = collect_result($p, $buildroot);
  $result->{'_log'} = "$buildroot/.build.log";
  return ('succeeded', $result);
}

1;
