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
use PBuild::RepoMgr;
use PBuild::AssetMgr;

#
# Create a new package status checker
#
sub create {
  my ($bconf, $arch, $buildtype, $pkgsrc, $builddir, $opts, $repomgr, $assetmgr) = @_;
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
    'repomgr' => $repomgr,
    'assetmgr' => $assetmgr,
  };
  $ctx->{'rebuild'} = $opts->{'buildtrigger'} if $opts->{'buildtrigger'};
  return bless $ctx;
}

#
# Configure the repositories used for package building
#
sub prepare {
  my ($ctx, $repos, $hostrepos) = @_;
  my $dep2pkg = PBuild::Expand::configure_repos($ctx->{'bconf'}, $repos);
  my %dep2src;
  my %subpacks;
  for my $n (sort keys %$dep2pkg) {
    my $bin = $dep2pkg->{$n};
    my $sn = $bin->{'source'};
    $sn = $n unless defined $n;
    $dep2src{$n} = $sn;
  }
  push @{$subpacks{$dep2src{$_}}}, $_ for keys %dep2src;
  $ctx->{'dep2src'} = \%dep2src;
  $ctx->{'dep2pkg'} = $dep2pkg;
  $ctx->{'subpacks'} = \%subpacks;
  PBuild::Meta::setgenmetaalgo($ctx->{'genmetaalgo'});
  $ctx->{'dep2pkg_host'} = PBuild::Expand::configure_repos($ctx->{'bconf_host'}, $hostrepos) if $ctx->{'bconf_host'};
}

#
# Expand the package dependencies of all packages
#
sub pkgexpand {
  my ($ctx, @pkgs) = @_;
  my $bconf = $ctx->{'bconf'};
  my $bconf_host = $ctx->{'bconf_host'};
  if (($bconf_host || $bconf)->{'expandflags:preinstallexpand'}) {
    my $err = Build::expandpreinstalls($bconf_host || $bconf);
    die("cannot expand preinstalls: $err\n") if $err;
  }
  my $pkgsrc = $ctx->{'pkgsrc'};
  my $subpacks = $ctx->{'subpacks'};
  my $cross = $bconf_host ? 1 : 0;
  for my $pkg (@pkgs) {
    my $p = $pkgsrc->{$pkg};
    if ($p->{'native'}) {
      PBuild::Expand::expand_deps($p, $bconf_host, $subpacks);
    } else {
      PBuild::Expand::expand_deps($p, $bconf, $subpacks, $cross);
    }
  }
}

#
# Sort the packages by dependencies
#
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

#
# Check all packages if they need to be rebuilt
#
sub pkgcheck {
  my ($ctx, $builders, @pkgs) = @_;

  my %packstatus;
  my %packdetails;

  $ctx->{'building'} = {};	# building
  $ctx->{'building'}->{$_->{'job'}->{'pdata'}->{'pkg'}} = $_->{'job'} for grep {$_->{'job'}} @$builders;
  $ctx->{'notready'} = {};	# building or blocked
  $ctx->{'nharder'} = 0;

  my $builddir = $ctx->{'builddir'};
  my $pkgsrc = $ctx->{'pkgsrc'};
  my $cychash = $ctx->{'cychash'};
  my %cycpass;
  my @cpacks = @pkgs;

  # now check every package
  while (@cpacks) {
    my $packid = shift @cpacks;

    # cycle handling code
    my $incycle = 0; 
    if ($cychash->{$packid}) {
      ($packid, $incycle) = handlecycle($ctx, $packid, \@cpacks, \%cycpass, \%packstatus);
      next unless $incycle;
    }
    my $p = $pkgsrc->{$packid};
    if ($p->{'error'}) {
      if ($p->{'error'} =~ /^(excluded|disabled|locked)(?::(.*))?$/) {
	$packstatus{$packid} = $1;
	$packdetails{$packid} = $2 if $2;
	next;
      }
      $packstatus{$packid} = 'broken';
      $packdetails{$packid} = $p->{'error'};
      next;
    }
    if ($p->{'dep_experror'}) {
      $packstatus{$packid} = 'unresolvable';
      $packdetails{$packid} = $p->{'dep_experror'};
      next;
    }

    if ($ctx->{'building'}->{$packid}) {
      my $job = $ctx->{'building'}->{$packid};
      $packstatus{$packid} = 'building';
      $packdetails{$packid} = "on builder $job->{'name'}" if $job->{'nbuilders'} > 1;
      $ctx->{'notready'}->{$p->{'name'} || $p->{'pkg'}} = 1 if $p->{'useforbuildenabled'};
      next;
    }

recheck_package:
    my ($status, $error) = check($ctx, $p, $incycle);
    #printf("%s -> %s%s", $packid, $status, $error && $status ne 'scheduled' ? " ($error)" : '');
    if ($status eq 'scheduled') {
      next if $ctx->{'singlejob'} && $ctx->{'singlejob'} ne $packid;
      my $builder;
      for (@$builders) {
	next if $_->{'job'};
	$builder = $_;
	last;
      }
      if (!$builder) {
	($status, $error) = ('waiting', undef);
      } else {
	($status, $error) = build($ctx, $p, $error, $builder);
      }
      goto recheck_package if $status eq 'recheck';	# assets changed
      if ($status eq 'building') {
	my $job = $error;
	$error = undef;
	$error = "on builder $job->{'name'}" if $job->{'nbuilders'} > 1;
        my $bid = ($builder->{'nbuilders'} || 1) > 1 ? "$builder->{'name'}: " : '';
	if ($p->{'native'}) {
          print "${bid}building $p->{'pkg'}/$p->{'recipe'} (native)\n";
	} else {
          print "${bid}building $p->{'pkg'}/$p->{'recipe'}\n";
        }
        $ctx->{'building'}->{$packid} = $builder->{'job'};
      }
      #printf("%s -> %s%s", $packid, $status, $error ? " ($error)" : '');
    } elsif ($status eq 'done') {
      # map done to succeeded/failed
      if (-e "$builddir/$packid/_meta.fail") {
	$status = 'failed';
      } else {
	$status = 'succeeded';
      }
    }
    if ($status eq 'blocked' || $status eq 'building' || $status eq 'waiting') {
      $ctx->{'notready'}->{$p->{'name'} || $p->{'pkg'}} = 1 if $p->{'useforbuildenabled'};
    }
    $packstatus{$packid} = $status;
    $packdetails{$packid} = $error if defined $error;
  }
  my %result;
  for my $packid (sort keys %packstatus) {
    my $r = { 'code' => $packstatus{$packid} };
    $r->{'details'} = $packdetails{$packid} if defined $packdetails{$packid};
    $result{$packid} = $r;
  }
  return \%result;
}

#
# Generate the dependency tracking data for a image/container
#
sub genmeta_image {
  my ($ctx, $p, $edeps) = @_;
  if ($p->{'buildtype'} eq 'preinstallimage') {
    my @pdeps = Build::get_preinstalls($ctx->{'bconf'});
    my @vmdeps = Build::get_vminstalls($ctx->{'bconf'});
    $edeps = [ PBuild::Util::unify(@$edeps, @pdeps, @vmdeps) ];
  }
  my $dep2pkg = $p->{'native'} ? $ctx->{'dep2pkg_host'} : $ctx->{'dep2pkg'};
  my @new_meta;
  for my $bin (@$edeps) {
    my $q = $dep2pkg->{$bin};
    push @new_meta, (($q || {})->{'hdrmd5'} || 'd0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0')."  $bin";
  }
  @new_meta = sort {substr($a, 34) cmp substr($b, 34) || $a cmp $b} @new_meta;
  unshift @new_meta, ($p->{'verifymd5'} || $p->{'srcmd5'})."  $p->{'pkg'}";
  return \@new_meta;
}

#
# Generate the dependency tracking data for a package
#
sub genmeta {
  my ($ctx, $p, $edeps, $hdeps) = @_;
  my $buildtype = $p->{'buildtype'};
  return genmeta_image($ctx, $p, $edeps) if $buildtype eq 'kiwi' || $buildtype eq 'docker' || $buildtype eq 'preinstallimage';
  my $dep2pkg = $p->{'native'} ? $ctx->{'dep2pkg_host'} : $ctx->{'dep2pkg'};
  my $metacache = $ctx->{'metacache'};
  my @new_meta;
  my $builddir = $ctx->{'builddir'};
  for my $bin (@$edeps) {
    my $q = $dep2pkg->{$bin};
    my $binpackid = $q->{'packid'};
    if (!defined $binpackid) {
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
    PBuild::Meta::add_meta(\@new_meta, $metacache->{$binpackid}, $bin, $p->{'pkg'});
  }
  if ($hdeps) {
    my $dep2pkg_host = $ctx->{'dep2pkg_host'};
    my $hostarch = $ctx->{'hostarch'};
    for my $bin (@$hdeps) {
      my $q = $dep2pkg_host->{$bin};
      push @new_meta, ($q->{'hdrmd5'} || 'd0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0')."  $hostarch:$bin";
    }
  }
  @new_meta = PBuild::Meta::gen_meta($ctx->{'subpacks'}->{$p->{'name'}} || [], @new_meta);
  unshift @new_meta, ($p->{'verifymd5'} || $p->{'srcmd5'})."  $p->{'pkg'}";
  return \@new_meta;
}

#
# Check the status of a single image/container
#
sub check_image {
  my ($ctx, $p) = @_;
  my $edeps = $p->{'dep_expanded'} || [];
  my $notready = $ctx->{'notready'};
  my $dep2src = $ctx->{'dep2src'};
  my @blocked = grep {$notready->{$dep2src->{$_}}} @$edeps;
  @blocked = () if $ctx->{'block'} && $ctx->{'block'} eq 'never';
  if (@blocked) {
    splice(@blocked, 10, scalar(@blocked), '...') if @blocked > 10;
    return ('blocked', join(', ', @blocked));
  }
  my $new_meta = genmeta($ctx, $p, $edeps);
  my $packid = $p->{'pkg'};
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
  return ('scheduled', [ { 'explain' => 'forced rebuild' } ]) if $p->{'force_rebuild'};
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

#
# Check the status of a single package
#
sub check {
  my ($ctx, $p, $incycle) = @_;

  my $buildtype = $p->{'buildtype'};
  return check_image($ctx, $p) if $buildtype eq 'kiwi' || $buildtype eq 'docker' || $buildtype eq 'preinstallimage';

  my $packid = $p->{'pkg'};
  my $notready = $ctx->{'notready'};
  my $dep2src = $ctx->{'dep2src'};
  my $edeps = $p->{'dep_expanded'} || [];
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
  # expand host deps
  my $hdeps;
  if ($ctx->{'bconf_host'} && !$p->{'native'}) {
    my $subpacks = $ctx->{'subpacks'};
    $hdeps = [ @{$p->{'dep_host'} || $p->{'dep'} || []} ];
    @$hdeps = Build::get_deps($ctx->{'bconf_host'}, $subpacks->{$p->{'name'}}, @$hdeps);
    if (!shift @$hdeps) {
      return ('unresolvable', 'host: '.join(', ', @$hdeps));
    }
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
    return ('scheduled', [ { 'explain' => 'new build' }, $hdeps ]);
  } elsif (substr($mylastcheck, 0, 32) ne ($p->{'verifymd5'} || $p->{'srcmd5'})) {
    return ('scheduled', [ { 'explain' => 'source change', 'oldsource' => substr($mylastcheck, 0, 32) }, $hdeps ]);
  } elsif ($p->{'force_rebuild'}) {
    return ('scheduled', [ { 'explain' => 'forced rebuild' }, $hdeps ]);
  } elsif (substr($mylastcheck, 32, 32) eq 'fakefakefakefakefakefakefakefake') {
    my @s = stat("$dst/_meta");
    if (!@s || $s[9] + 14400 > time()) {
      return ('failed')
    }
    return ('scheduled', [ { 'explain' => 'retrying bad build' }, $hdeps ]);
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

    my $dep2pkg = $p->{'native'} ? $ctx->{'dep2pkg_host'} : $ctx->{'dep2pkg'};
    my $dep2pkg_host = $ctx->{'dep2pkg_host'};
    $check .= $ctx->{'genmetaalgo'} if $ctx->{'genmetaalgo'};
    $check .= $rebuildmethod;
    $check .= $dep2pkg->{$_}->{'hdrmd5'} || 'd0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0' for sort @$edeps;
    $check .= $dep2pkg_host->{$_}->{'hdrmd5'} || 'd0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0' for sort @{$hdeps || []};
    $check = Digest::MD5::md5_hex($check);
    if ($check eq substr($mylastcheck, 64, 32)) {
      # print "      - $packid ($buildtype)\n";
      # print "        nothing changed\n";
      goto relsynccheck;
    }
    substr($mylastcheck, 64, 32) = $check;	# substitute new hdrmetamd5
    # even more work, generate new meta, check if it changed
    my $new_meta = genmeta($ctx, $p, $edeps, $hdeps);
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
    return ('scheduled', [ { 'explain' => 'meta change', 'packagechange' => $reason }, $hdeps ] );
  }
relsynccheck:
  if ($ctx->{'relsynctrigger'}->{$packid}) {
    return ('scheduled', [ { 'explain' => 'rebuild counter sync' }, $hdeps ] );
  }
  return ('done');
}

#
# Build dependency cycle handling
#
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

#
# Convert binary names to binary objects
#
sub dep2bins {
  my ($ctx, @deps) = @_;
  my $dep2pkg = $ctx->{'dep2pkg'};
  for (@deps) {
    my $q = $dep2pkg->{$_};
    die("unknown binary $_\n") unless $q;
    $_ = $q;
  }
  return \@deps;
}

sub dep2bins_host {
  my ($ctx, @deps) = @_;
  my $dep2pkg = $ctx->{'dep2pkg_host'} || $ctx->{'dep2pkg'};
  for (@deps) {
    my $q = $dep2pkg->{$_};
    die("unknown binary $_\n") unless $q;
    $_ = $q;
  }
  return \@deps;
}

#
# Start the build of a package
#
sub build {
  my ($ctx, $p, $data, $builder) = @_;
  my $packid = $p->{'pkg'};
  my $reason = $data->[0];
  my $hdeps = $data->[1];
  #print Dumper($reason);
  my $nounchanged = 1 if $packid && $ctx->{'cychash'}->{$packid};
  my @btdeps;
  my $edeps = $p->{'dep_expanded'} || [];
  my $bconf = $ctx->{'bconf_host'} || $ctx->{'bconf'};
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
  if (!$kiwimode && $ctx->{'bconf_host'}) {
    unshift @bdeps, @{$p->{'dep_host'} || $p->{'dep'} || []}, @btdeps;
  } else {
    unshift @bdeps, @{$p->{'dep'} || []}, @btdeps;
  }
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
    return ('unresolvable', 'sysdeps:' . join(', ', @sysdeps));
  }
  my $dep2pkg = $ctx->{'dep2pkg_host'} || $ctx->{'dep2pkg'};
  my @pdeps = Build::get_preinstalls($bconf);
  my @vmdeps = Build::get_vminstalls($bconf);
  my @missing = grep {!$dep2pkg->{$_}} (@pdeps, @vmdeps);
  if (@missing) {
    my $missing = join(', ', sort(BSUtil::unify(@missing)));
    return ('unresolvable', "missing pre/vminstalls: $missing");
  }
  my $tdeps;
  $tdeps = [ @$edeps ] if !$kiwimode && !$p->{'native'} && $ctx->{'bconf_host'};
  my $oldsrcmd5 = $p->{'srcmd5'};
  $ctx->{'assetmgr'}->getremoteassets($p);
  return ('recheck', 'assets changed') if $p->{'srcmd5'} ne $oldsrcmd5;
  return ('broken', $p->{'error'}) if $p->{'error'};	# missing assets
  my $bins;
  if ($kiwimode && $ctx->{'bconf_host'}) {
    $bins = dep2bins_host($ctx, PBuild::Util::unify(@pdeps, @vmdeps, @sysdeps));
    push @$bins, @{dep2bins($ctx, PBuild::Util::unify(@bdeps))};
  } else {
    $bins = dep2bins_host($ctx, PBuild::Util::unify(@pdeps, @vmdeps, @sysdeps, @bdeps));
    push @$bins, @{dep2bins($ctx, PBuild::Util::unify(@$tdeps))} if $tdeps;
  }
  $ctx->{'repomgr'}->getremotebinaries($bins);
  my $readytime = time();
  my $job = PBuild::Job::createjob($ctx, $builder->{'name'}, $builder->{'nbuilders'}, $builder->{'root'}, $p, \@bdeps, \@pdeps, \@vmdeps, \@sysdeps, $tdeps, $nounchanged);
  $job->{'readytime'} = $readytime;
  $job->{'reason'} = $reason;
  $job->{'hostarch'} = $ctx->{'hostarch'};
  # calculate meta (again) as remote binaries have been replaced
  $job->{'meta'} = genmeta($ctx, $p, $edeps, $hdeps);
  $builder->{'job'} = $job;
  return ('building', $job);
}

1;
