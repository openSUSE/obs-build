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

package PBuild::Repoquery;

use strict;

use Build;
use Build::Rpm;
use PBuild::Expand;
use PBuild::Modules;

#
# match a parsed complex dependency against a set of provides
#
sub matchdeps_cplx {
  my ($pp, $r, $binarytype) = @_;
  if ($r->[0] == 0) {
    for my $p (@$pp) {
      return 1 if Build::matchsingledep($p, $r->[1], $binarytype);
    }
  } elsif ($r->[0] == 1 || $r->[0] == 2) {	# and or
    return 1 if matchdeps_cplx($pp, $r->[1], $binarytype);
    return 1 if matchdeps_cplx($pp, $r->[2], $binarytype);
  } elsif ($r->[0] == 3 || $r->[0] == 4) {	# if unless
    return 1 if matchdeps_cplx($pp, $r->[1], $binarytype);
    return 1 if @$r == 4 && matchdeps_cplx($pp, $r->[3], $binarytype);
  } elsif ($r->[0] == 6) {			# with
    return 1 if matchdeps_cplx($pp, $r->[1], $binarytype) && matchdeps_cplx($pp, $r->[2], $binarytype);
  } elsif ($r->[0] == 7) {			# without
    return 1 if matchdeps_cplx($pp, $r->[1], $binarytype) && !matchdeps_cplx($pp, $r->[2], $binarytype);
  }
  return 0;
}

#
# match a dependency against a single provides
#
sub matchdep {
  my ($p, $d, $binarytype) = @_;
  if ($d =~ /\|/) {
    # debian or
    for my $od (split(/\s*\|\s*/, $d)) {
      return 1 if Build::matchsingledep($p, $od, $binarytype);
    }
    return 0;
  }
  return Build::matchsingledep($p, $d, $binarytype);
}

#
# compare to packages by epoch/version/release
#
sub evrcmp {
  my ($obin, $bin, $verscmp) = @_;
  my $evr = $bin->{'version'};
  $evr = "$bin->{'epoch'}:$evr" if $bin->{'epoch'};
  $evr .= "-$bin->{'release'}" if defined $bin->{'release'};
  my $oevr = $obin->{'version'};
  $oevr = "$obin->{'epoch'}:$oevr" if $obin->{'epoch'};
  $oevr .= "-$obin->{'release'}" if defined $obin->{'release'};
  return 0 if $oevr eq $evr;
  return $verscmp->($oevr, $evr) || $oevr cmp $evr;
}

#
# compare to packages by architecure (noarch > otherarch)
#
sub archcmp {
  my ($obin, $bin) = @_;
  my $arch = $bin->{'arch'} || '';
  $arch = 'noarch' if !$arch || $arch eq 'all' || $arch eq 'any';
  my $oarch = $obin->{'arch'} || '';
  $oarch = 'noarch' if !$oarch || $oarch eq 'all' || $oarch eq 'any';
  return -1 if $arch eq 'noarch' && $oarch ne 'noarch';
  return 1 if $oarch eq 'noarch' && $arch ne 'noarch';
  return $oarch cmp $arch;
}

#
# return true if a package is not selected by the configured modules
#
sub ispruned {
  my ($modules, $moduledata, $bin) = @_;
  return 0 unless $moduledata;
  my @modules = PBuild::Modules::getmodules($moduledata, $bin);
  return 0 unless @modules;
  my $pruned = PBuild::Modules::prune_to_modules($modules, $moduledata, [ $bin ]);
  return @$pruned ? 0 : 1;
}

#
# match the available packages against a given query
#
sub repoquery {
  my ($bconf, $myarch, $repos, $query, $opts) = @_;
  my @query = @{$query || []};
  die("Please specify a query\n") unless @query;
  for (@query) {
    if (/^(name|requires|provides|conflicts|recommends|supplements|obsoletes):(.*)$/) {
      $_ = [ $1, $2 ];
    } else {
      $_ = [ 'provides', $_ ];
    }
    if ($_->[1] =~ /^\(.*\)$/) {
      $_->[3] = Build::Rpm::parse_rich_dep($_->[1]);
    } elsif ($_->[1] =~ /\|/) {
      $_->[2] = undef;	# debian or
    } elsif ($_->[1] !~ /^(.*?)\s*([<=>]{1,2})\s*(.*?)$/) {
      $_->[2] = $_->[1];
    } else {
      $_->[2] = $1;
    }
    $_->[2] = qr/^\Q$_->[2]\E/ if defined $_->[2];
    if ($_->[0] ne 'name' && $_->[0] ne 'provides') {
      die("provides '$_->[1]' cannot be complex\n") if $_->[3];
      die("provides '$_->[1]' cannot use debian or\n") if $_->[1] =~ /\|/;
      die("provides '$_->[1]' not supported\n") unless defined $_->[2];
    }
  }
  my $binarytype = $bconf->{'binarytype'};
  my $verscmp = $binarytype eq 'deb' ? \&Build::Deb::verscmp : \&Build::Rpm::verscmp;
  my $packs = PBuild::Expand::configure_repos($bconf, $repos);
  for my $repo (@$repos) {
    my $bins = $repo->{'bins'} || [];
    my $moduledata;
    $moduledata = $bins->[-1]->{'data'} if @$bins && $bins->[-1]->{'name'} eq 'moduleinfo:';
    my $repoprinted;
    for my $bin (@$bins) {
      next if $bin->{'name'} eq 'moduleinfo:';
      my $match;
      for my $q (@query) {
        my $dd;
	if ($q->[0] eq 'name') {
	  my $evr = $bin->{'version'};
	  $evr = "$bin->{'epoch'}:$evr" if $bin->{'epoch'};
	  $evr .= "-$bin->{'release'}" if defined $bin->{'release'};
	  $dd = [ "$bin->{'name'} = $evr" ];
	} else {
          $dd = $bin->{$q->[0]};
	}
	next unless $dd;
	if ($q->[0] eq 'name' || $q->[0] eq 'provides') {
	  if ($q->[3]) {
	    if (matchdeps_cplx($dd, $q->[3], $binarytype)) {
	      $match = 1;
	      last;
	    }
	    next;
	  }
	  if (!defined($q->[2])) {
	    # cannot pre-filter (e.g. debian or)
	    for my $d (@$dd) {
	      if (matchdep($d, $q->[1], $binarytype)) {
	        $match = 1;
	        last;
	      }
	    }
	  } else {
	    for my $d (grep {/$q->[2]/} @$dd) {
	      if (matchdep($d, $q->[1], $binarytype)) {
	        $match = 1;
	        last;
	      }
	    }
	  }
	} else {
	  for my $d (grep {/$q->[2]/} @$dd) {
	    if (matchdep($q->[1], $d, $binarytype)) {
	      $match = 1;
	      last;
	    }
	  }
	}
	last if $match;
      }
      next unless $match;
      my $excluded;
      my $taken = $packs->{$bin->{'name'}};
      if (($taken || 0) != $bin) {
	$excluded = 'unknown' unless $taken;
	$excluded = 'unselected module' if !$excluded && ispruned($bconf->{'modules'}, $moduledata, $bin);
	$excluded = 'repo layering' if !$excluded && $taken->{'repoid'} ne $bin->{'repoid'};
	$excluded = 'smaller version' if !$excluded && evrcmp($taken, $bin, $verscmp) >= 0;
	$excluded = 'smaller architecture' if !$excluded && archcmp($taken, $bin) >= 0;
        $excluded ||= 'unknown';
      }
      my $evr = $bin->{'version'};
      $evr = "$bin->{'epoch'}:$evr" if $bin->{'epoch'};
      $evr .= "-$bin->{'release'}" if defined $bin->{'release'};
      my $nevra = "$bin->{'name'}-$evr.$bin->{'arch'}";
      my $from = $repo->{'type'} eq 'local' ? 'build result' : $repo->{'url'};
      if ($opts->{'details'}) {
	print "$nevra\n";
	print "  repo: $from\n";
	print "  excluded: $excluded\n" if $excluded;
	#print "  location: $bin->{'location'}\n" if $bin->{'location'};
	#print "  checksum: $bin->{'checksum'}\n" if $bin->{'checksum'};
	my @modules;
	@modules = PBuild::Modules::getmodules($moduledata, $bin) if $moduledata;
	if (@modules) {
	  print "  modules:\n";
	  print "    - $_\n" for @modules;
	}
	for my $d (qw{provides requires conflicts obsoletes recommends supplements suggests enhances}) {
	  my $dd = $bin->{$d};
	  next unless @{$dd || []};
	  print "  $d:\n";
	  print "    - $_\n" for @$dd;
	}
      } else {
	if (!$repoprinted) {
	  print "repo: $from\n";
	  $repoprinted = 1;
	}
	if ($excluded) {
	  $excluded = '<v' if $excluded eq 'smaller version';
	  $excluded = '<a' if $excluded eq 'smaller architecture';
	  $excluded = '<r' if $excluded eq 'repo layering';
	  $excluded = '!m' if $excluded eq 'unselected module';
	  $excluded = '??' if length($excluded) != 2;
	} else {
	  $excluded = '  ';
	}
	print "  $excluded  $nevra\n";
      }
    }
  }
}

1;
