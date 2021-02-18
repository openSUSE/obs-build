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

package PBuild::Checker;

use strict;
use Digest::MD5 ();
use Data::Dumper;

use PBuild::Expand;
use PBuild::Depsort;
use PBuild::Meta;
use PBuild::Util;
use PBuild::Job;
use PBuild::LocalRepo;
use PBuild::RemoteRepo;
use PBuild::RemoteRegistry;

#
# Create a checker
#
sub create {
  my ($bconf, $arch, $buildtype, $pkgsrc, $builddir, $opts) = @_;
  my $genmetaalgo = $bconf->{'buildflags:genmetaalgo'};
  $genmetaalgo = 1 unless defined $genmetaalgo;
  my $ctx = {
    'bconf' => $bconf,
    'arch' => $arch,
    'buildtype' => $buildtype,
    'opts' => $opts,
    'pkgsrc' => $pkgsrc,
    'builddir' => $builddir,
    'block' => undef,		# block strategy   (all,never)
    'rebuild' => undef,		# rebuild strategy (transitive,direct,local)
    'debuginfo' => 1,		# create debug packages?
    'genmetaalgo' => $genmetaalgo,
    'lastcheck' => {},
    'metacache' => {},
  };
  return bless $ctx;
}

sub prepare {
  my ($ctx, $repos) = @_;
  my $repodata = PBuild::Expand::configure_repos($ctx->{'bconf'}, $repos);
  my %dep2src;
  my %dep2pkg;
  my %subpacks;
  for my $n (sort keys %$repodata) {
    my $bin = $repodata->{$n};
    my $sn = $bin->{'source'};
    $sn = $n unless defined $n;
    $dep2pkg{$n} = $bin;
    $dep2src{$n} = $sn;
  }
  push @{$subpacks{$dep2src{$_}}}, $_ for keys %dep2src;
  $ctx->{'dep2src'} = \%dep2src;
  $ctx->{'dep2pkg'} = \%dep2pkg;
  $ctx->{'subpacks'} = \%subpacks;
  $ctx->{'repos'} = $repos;
  $ctx->{'repodata'} = $repodata;
  PBuild::Meta::setgenmetaalgo($ctx->{'genmetaalgo'});
}

sub pkgexpand {
  my ($ctx, @pkgs) = @_;
  my $bconf = $ctx->{'bconf'};
  if ($bconf->{'expandflags:preinstallexpand'}) {
    my $err = Build::expandpreinstalls($bconf);
    die("cannot expand preinstalls: $err\n") if $err;
  }
  my $pkgsrc = $ctx->{'pkgsrc'};
  my $subpacks = $ctx->{'subpacks'};
  for my $pkg (@pkgs) {
    PBuild::Expand::expand_deps($pkgsrc->{$pkg}, $bconf, $subpacks);
  }
}

sub pkgsort {
  my ($ctx, @pkgs) = @_;
  my %pdeps;
  my %pkg2src;
  my $pkgsrc = $ctx->{'pkgsrc'};
  for my $pkg (@pkgs) {
    my $p = $pkgsrc->{$pkg};
    $pdeps{$pkg} = $p->{'dep_expanded'} || []; 
    $pkg2src{$pkg} = $p->{'name'} || $p->{'pkg'};
  }
  my @cycles;
  @pkgs = PBuild::Depsort::depsort2(\%pdeps, $ctx->{'dep2src'}, \%pkg2src, \@cycles, @pkgs);
  my %cychash;
  for my $cyc (@cycles) {
    next if @$cyc < 2;  # just in case
    my @c = map {@{$cychash{$_} || [ $_ ]}} @$cyc;
    @c = PBuild::Util::unify(sort(@c));
    $cychash{$_} = \@c for @c; 
  }
  #if (%cychash) {
  #  print "  cycle components:\n";
  #  for (PBuild::Util::unify(sort(map {$_->[0]} values %cychash))) {
  #    print "    - @{$cychash{$_}}\n";
  #  }
  #}
  $ctx->{'cychash'} = \%cychash;
  return @pkgs;
}

sub genmeta {
  my ($ctx, $p, $edeps, $repodata) = @_;
  if ($p->{'buildtype'} eq 'kiwi' || $p->{'buildtype'} eq 'docker' || $p->{'buildtype'} eq 'preinstallimage') {
    if ($p->{'buildtype'} eq 'preinstallimage') {
      my @pdeps = Build::get_preinstalls($ctx->{'bconf'});
      my @vmdeps = Build::get_vminstalls($ctx->{'bconf'});
      $edeps = [ PBuild::Util::unify(@$edeps, @pdeps, @vmdeps) ];
    }
    my @new_meta;
    for my $bin (@$edeps) {
      my $q = $repodata->{$bin};
      push @new_meta, (($q || {})->{'hdrmd5'} || 'd0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0')."  $bin";
    }
    @new_meta = sort {substr($a, 34) cmp substr($b, 34) || $a cmp $b} @new_meta;
    unshift @new_meta, ($p->{'verifymd5'} || $p->{'srcmd5'})."  $p->{'pkg'}";
    return \@new_meta;
  }
  my $metacache = $ctx->{'metacache'};
  my @new_meta;
  my $builddir = $ctx->{'builddir'};
  for my $bin (@$edeps) {
    my $q = $repodata->{$bin};
    my $binpackid = $q->{'packid'};
    if (!$binpackid) {
      # use the hdrmd5 for non-local packages
      push @new_meta, ($q->{'hdrmd5'} || 'd0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0')."  $bin";
      next;
    }
    # meta file is not in cache, read it
    if (!exists $metacache->{$binpackid}) {
      my $mf = "$builddir/$q->{'packid'}/_meta.success";
      my $mfd;
      die("$mf: $!\n") unless open($mfd, '<', $mf);
      local $/ = undef;
      $metacache->{$binpackid} = <$mfd>;
      close($mfd);
      die("$mf: bad meta\n") unless length($metacache->{$binpackid}) > 34;
    }
    PBuild::Meta::add_meta(\@new_meta, $metacache->{$q->{'packid'}}, $bin, $p->{'pkg'});
  }
  @new_meta = PBuild::Meta::gen_meta($ctx->{'subpacks'}->{$p->{'name'}} || [], @new_meta);
  unshift @new_meta, ($p->{'verifymd5'} || $p->{'srcmd5'})."  $p->{'pkg'}";
  return \@new_meta;
}

sub check_image {
  my ($ctx, $packid) = @_;
  my $bconf = $ctx->{'bconf'};
  my $p = $ctx->{'pkgsrc'}->{$packid};
  my $edeps = $p->{'dep_expanded'} || [];
  my $notready = $ctx->{'notready'};
  my $dep2src = $ctx->{'dep2src'};
  my @blocked = grep {$notready->{$dep2src->{$_}}} @$edeps;
  @blocked = () if $ctx->{'block'} && $ctx->{'block'} eq 'never';
  if (@blocked) {
    splice(@blocked, 10, scalar(@blocked), '...') if @blocked > 10;
    return ('blocked', join(', ', @blocked));
  }
  my $new_meta = genmeta($ctx, $p, $edeps, $ctx->{'repodata'});
  my $dst = "$ctx->{'builddir'}/$packid";
  my @meta;
  my $mfp;
  if (open($mfp, '<', "$dst/_meta")) {
    @meta = <$mfp>;
    close $mfp;
    chomp @meta;
  }
  return ('scheduled', [ { 'explain' => 'new build' } ]) if !@meta;
  return ('scheduled', [ { 'explain' => 'source change', 'oldsource' => substr($meta[0], 0, 32) } ]) if $meta[0] ne $new_meta->[0];
  my $rebuildmethod = $ctx->{'rebuild'} || 'transitive';
  if ($rebuildmethod eq 'local') {
    return ('scheduled', [ { 'explain' => 'rebuild counter sync' } ]) if $ctx->{'relsynctrigger'}->{$packid};
    return ('done');
  }
  if (@meta == @$new_meta && join('\n', @meta) eq join('\n', @$new_meta)) {
    return ('scheduled', [ { 'explain' => 'rebuild counter sync' } ]) if $ctx->{'relsynctrigger'}->{$packid};
    return ('done');
  }
  my @diff = PBuild::Meta::diffsortedmd5(\@meta, $new_meta);
  my $reason = PBuild::Meta::sortedmd5toreason(@diff);
  return ('scheduled', [ { 'explain' => 'meta change', 'packagechange' => $reason } ] );
}

sub check {
  my ($ctx, $packid, $incycle) = @_;

  my $p = $ctx->{'pkgsrc'}->{$packid};
  my $buildtype = $p->{'buildtype'};
  return check_image($ctx, $packid) if $buildtype eq 'kiwi' || $buildtype eq 'docker' || $buildtype eq 'preinstallimage';

  my $notready = $ctx->{'notready'};
  my $dep2src = $ctx->{'dep2src'};
  my $edeps = $p->{'dep_expanded'} || [];
  my $myarch = $ctx->{'arch'};
  my $dst = "$ctx->{'builddir'}/$packid";

  # calculate if we're blocked
  my @blocked = grep {$notready->{$dep2src->{$_}}} @$edeps;
  @blocked = () if $ctx->{'block'} && $ctx->{'block'} eq 'never';
  # check if cycle builds are in progress
  if ($incycle && $incycle == 3) {
    push @blocked, 'cycle' unless @blocked;
    splice(@blocked, 10, scalar(@blocked), '...') if @blocked > 10;
    return ('blocked', join(', ', @blocked));
  }
  # prune cycle packages from blocked
  if ($incycle) {
    my $pkgsrc = $ctx->{'pkgsrc'};
    my %cycs = map {(($pkgsrc->{$_} || {})->{'name'} || $_) => 1} @{$ctx->{'cychash'}->{$packid}};
    @blocked = grep {!$cycs{$dep2src->{$_}}} @blocked;
  }
  if (@blocked) {
    # print "      - $packid ($buildtype)\n";
    # print "        blocked\n";
    splice(@blocked, 10, scalar(@blocked), '...') if @blocked > 10;
    return ('blocked', join(', ', @blocked));
  }
  my $reason;
  my @meta_s = stat("$dst/_meta");
  # we store the lastcheck data in one string instead of an array
  # with 4 elements to save precious memory
  # srcmd5.metamd5.hdrmetamd5.statdata (32+32+32+x)
  my $lastcheck = $ctx->{'lastcheck'};
  my $mylastcheck = $lastcheck->{$packid};
  my @meta;
  if (!@meta_s || !$mylastcheck || substr($mylastcheck, 96) ne "$meta_s[9]/$meta_s[7]/$meta_s[1]") {
    if (open(F, '<', "$dst/_meta")) {
      @meta_s = stat F;
      @meta = <F>;
      close F;
      chomp @meta;
      $mylastcheck = substr($meta[0], 0, 32);
      if (@meta == 2 && $meta[1] =~ /^fake/) {
        $mylastcheck .= 'fakefakefakefakefakefakefakefake';
      } else {
        $mylastcheck .= Digest::MD5::md5_hex(join("\n", @meta));
      }
      $mylastcheck .= 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx';	# fake hdrmetamd5
      $mylastcheck .= "$meta_s[9]/$meta_s[7]/$meta_s[1]";
      $lastcheck->{$packid} = $mylastcheck;
    } else {
      delete $lastcheck->{$packid};
      undef $mylastcheck;
    }
  }
  if (!$mylastcheck) {
    return ('scheduled', [ { 'explain' => 'new build' } ]);
  } elsif (substr($mylastcheck, 0, 32) ne ($p->{'verifymd5'} || $p->{'srcmd5'})) {
    return ('scheduled', [ { 'explain' => 'source change', 'oldsource' => substr($mylastcheck, 0, 32) } ]);
  } elsif (substr($mylastcheck, 32, 32) eq 'fakefakefakefakefakefakefakefake') {
    my @s = stat("$dst/_meta");
    if (!@s || $s[9] + 14400 > time()) {
      return ('failed')
    }
    return ('scheduled', [ { 'explain' => 'retrying bad build' } ]);
  } else {
    my $rebuildmethod = $ctx->{'rebuild'} || 'transitive';
    if ($rebuildmethod eq 'local' || $p->{'hasbuildenv'}) {
      # rebuild on src changes only
      goto relsynccheck;
    }
    # more work, check if dep rpm changed
    if ($incycle == 1) {
      # print "      - $packid ($buildtype)\n";
      # print "        in cycle, no source change...\n";
      return ('done');
    }
    my $check = substr($mylastcheck, 32, 32);	# metamd5

    my $repodata = $ctx->{'repodata'};
    $check .= $ctx->{'genmetaalgo'} if $ctx->{'genmetaalgo'};
    $check .= $rebuildmethod;
    $check .= $repodata->{$_}->{'hdrmd5'} || 'd0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0' for sort @$edeps;
    $check = Digest::MD5::md5_hex($check);
    if ($check eq substr($mylastcheck, 64, 32)) {
      # print "      - $packid ($buildtype)\n";
      # print "        nothing changed\n";
      goto relsynccheck;
    }
    substr($mylastcheck, 64, 32) = $check;	# substitute new hdrmetamd5
    # even more work, generate new meta, check if it changed
    my $new_meta = genmeta($ctx, $p, $edeps, $repodata);
    if (Digest::MD5::md5_hex(join("\n", @$new_meta)) eq substr($mylastcheck, 32, 32)) {
      # print "      - $packid ($buildtype)\n";
      # print "        nothing changed (looked harder)\n";
      $ctx->{'nharder'}++;
      $lastcheck->{$packid} = $mylastcheck;
      goto relsynccheck;
    }
    # something changed, read in old meta (if not already done)
    if (!@meta && open(F, '<', "$dst/_meta")) {
      @meta = <F>;
      close F;
      chomp @meta;
    }
    if ($rebuildmethod eq 'direct') {
      @meta = grep {!/\//} @meta;
      @$new_meta = grep {!/\//} @$new_meta;
    }
    if (@meta == @$new_meta && join('\n', @meta) eq join('\n', @$new_meta)) {
      # print "      - $packid ($buildtype)\n";
      # print "        nothing changed (looked harder)\n";
      $ctx->{'nharder'}++;
      if ($rebuildmethod eq 'direct') {
        $lastcheck->{$packid} = $mylastcheck;
      } else {
        # should not happen, delete lastcheck cache
        delete $lastcheck->{$packid};
      }
      goto relsynccheck;
    }
    my @diff = PBuild::Meta::diffsortedmd5(\@meta, $new_meta);
    my $reason = PBuild::Meta::sortedmd5toreason(@diff);
    return ('scheduled', [ { 'explain' => 'meta change', 'packagechange' => $reason } ] );
  }
relsynccheck:
  if ($ctx->{'relsynctrigger'}->{$packid}) {
    return ('scheduled', [ { 'explain' => 'rebuild counter sync' } ] );
  }
  return ('done');
}

sub getremotebinaries {
  my ($ctx, @bins) = @_;
  my %tofetch;
  my $repodata = $ctx->{'repodata'};
  for my $bin (PBuild::Util::unify(@bins)) {
    my $q = $repodata->{$bin};
    die("unknown binary $bin?\n") unless $q;
    next if $q->{'filename'};
    my $repono = $q->{'repono'};
    die("binary $bin does not belong to a repo?\n") unless defined $repono;
    push @{$tofetch{$repono}}, $q;
  }
  for my $repono (sort {$a <=> $b} keys %tofetch) {
    my $repo = $ctx->{'repos'}->[$repono];
    if ($repo->{'type'} eq 'repo') {
      PBuild::RemoteRepo::fetchbinaries($repo, $tofetch{$repono});
    } elsif ($repo->{'type'} eq 'registry') {
      PBuild::RemoteRegistry::fetchbinaries($repo, $tofetch{$repono});
    }
  }
}

sub handlecycle {
  my ($ctx, $packid, $cpacks, $cycpass, $packstatus) = @_;

  my $incycle = 0; 
  my $cychash = $ctx->{'cychash'};
  return ($packid, 0) unless $cychash->{$packid};
  # do every package in the cycle twice:
  # pass1: only build source changes
  # pass2: normal build, but block if a pass1 package is building
  # pass3: ignore
  $incycle = $cycpass->{$packid};
  if (!$incycle) {
    # starting pass 1       (incycle == 1)
    my @cycp = @{$cychash->{$packid}};
    unshift @$cpacks, $cycp[0];      # pass3
    unshift @$cpacks, @cycp;         # pass2
    unshift @$cpacks, @cycp;         # pass1
    $packid = shift @$cpacks;
    $incycle = 1; 
    $cycpass->{$_} = $incycle for @cycp;
    $cycpass->{$packid} = -1;         # pass1 ended
  } elsif ($incycle == -1) {
    # starting pass 2       (incycle will be 2 or 3)
    my @cycp = @{$cychash->{$packid}};
    $incycle = (grep {$ctx->{'building'}->{$_}} @cycp) ? 3 : 2;
    $cycpass->{$_} = $incycle for @cycp;
    $cycpass->{$packid} = -2;         # pass2 ended
  } elsif ($incycle == -2) {
    # starting pass 3       (incycle == 4)
    my @cycp = @{$cychash->{$packid}};
    $incycle = 4;
    $cycpass->{$_} = $incycle for @cycp;
    # propagate notready to all cycle packages
    my $notready = $ctx->{'notready'};
    my $pkgsrc = $ctx->{'pkgsrc'};
    if (grep {$notready->{($pkgsrc->{$_} || {})->{'name'} || $_}} @cycp) {
      $notready->{($pkgsrc->{$_} || {})->{'name'} || $_} ||= 1 for @cycp;
    }
  }
  return ($packid, undef) if $incycle == 4;    # ignore after pass1/2
  return ($packid, undef) if $packstatus->{$packid} && $packstatus->{$packid} ne 'done' && $packstatus->{$packid} ne 'succeeded' && $packstatus->{$packid} ne 'failed'; # already decided
  return ($packid, $incycle);
}

sub build {
  my ($ctx, $packid, $data, $builder) = @_;
  my $reason = $data->[0];
  #print Dumper($reason);
  my $nounchanged = 1 if $packid && $ctx->{'cychash'}->{$packid};
  my @btdeps;
  my $p = $ctx->{'pkgsrc'}->{$packid};
  die if $p->{'pkg'} ne $packid;	# just in case
  my $edeps = $p->{'dep_expanded'} || [];
  my $bconf = $ctx->{'bconf'};
  my $buildtype = $p->{'buildtype'};
  $buildtype = 'kiwi-image' if $buildtype eq 'kiwi';
  my $kiwimode;
  $kiwimode = $buildtype if $buildtype eq 'kiwi-image' || $buildtype eq 'kiwi-product' || $buildtype eq 'docker' || $buildtype eq 'fissile';

  if ($p->{'buildtimeservice'}) {
    for my $service (@{$p->{'buildtimeservice'} || []}) {
      if ($bconf->{'substitute'}->{"obs-service:$service"}) {
        push @btdeps, @{$bconf->{'substitute'}->{"obs-service:$service"}};
      } else {
        my $pkgname = "obs-service-$service";
        $pkgname =~ s/_/-/g if $bconf->{'binarytype'} eq 'deb';
        push @btdeps, $pkgname;
      }
    }
    @btdeps = PBuild::Util::unify(@btdeps);
  }
  my @sysdeps = @btdeps;
  unshift @sysdeps, grep {/^kiwi-.*:/} @{$p->{'dep'} || []} if $buildtype eq 'kiwi-image';
  if (@sysdeps) {
    @sysdeps = Build::get_sysbuild($bconf, $buildtype, [ @sysdeps ]);   # cannot cache...
  } else {
    $ctx->{"sysbuild_$buildtype"} ||= [ Build::get_sysbuild($bconf, $buildtype) ];
    @sysdeps = @{$ctx->{"sysbuild_$buildtype"}};
  }
  @btdeps = () if @sysdeps;     # already included in sysdeps
  my $genbuildreqs = $p->{'genbuildreqs'};
  my @bdeps = grep {!/^\// || $bconf->{'fileprovides'}->{$_}} @{$p->{'prereq'} || []};
  unshift @bdeps, '--directdepsend--' if @bdeps;
  unshift @bdeps, @{$genbuildreqs->[1]} if $genbuildreqs;
  unshift @bdeps, @{$p->{'dep'} || []}, @btdeps;
  push @bdeps, '--ignoreignore--' if @sysdeps || $buildtype eq 'simpleimage';
  if (exists($bconf->{'buildflags:useccache'}) && ($buildtype eq 'arch' || $buildtype eq 'spec' || $buildtype eq 'dsc')) {
    my $opackid = $packid;
    $opackid = $p->{'releasename'} if $p->{'releasename'};
    if (grep {$_ eq "useccache:$opackid" || $_ eq "useccache:$packid"} @{$bconf->{'buildflags'} || []}) {
      push @bdeps, @{$bconf->{'substitute'}->{'build-packages:ccache'} || [ 'ccache' ] };
    }
  }
  if ($kiwimode || $buildtype eq 'buildenv' || $buildtype eq 'preinstallimage') {
    @bdeps = (1, @$edeps);      # reuse edeps packages, no need to expand again
  } else {
    @bdeps = Build::get_build($bconf, $ctx->{'subpacks'}->{$p->{'name'}}, @bdeps);
  }
  if (!shift(@bdeps)) {
    return ('unresolvable', join(', ', @bdeps));
  }
  if (@sysdeps && !shift(@sysdeps)) {
    return ('unresolvable', join(', ', @sysdeps));
  }
  my @pdeps = Build::get_preinstalls($bconf);
  my @vmdeps = Build::get_vminstalls($bconf);
  my @missing = grep {!$ctx->{'dep2pkg'}->{$_}} (@pdeps, @vmdeps);
  if (@missing) {
    my $missing = join(', ', sort(BSUtil::unify(@missing)));
    return ('unresolvable', "missing pre/vminstalls: $missing");
  }
  getremotebinaries($ctx, @pdeps, @vmdeps, @sysdeps, @bdeps);
  my $readytime = time();
  my $job = PBuild::Job::createjob($ctx, $builder->{'name'}, $builder->{'nbuilders'}, $builder->{'root'}, $p, \@bdeps, \@pdeps, \@vmdeps, \@sysdeps, $nounchanged);
  $job->{'readytime'} = $readytime;
  $job->{'reason'} = $reason;
  $job->{'hostarch'} = $ctx->{'hostarch'};
  # calculate meta (again) as remote binaries have been replaced
  $job->{'meta'} = genmeta($ctx, $p, $edeps, $ctx->{'repodata'});
  $builder->{'job'} = $job;
  return ('building', $job);
}

1;
