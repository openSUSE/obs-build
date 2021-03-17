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

package PBuild::Modules;

use strict;

use PBuild::Util;

#
# reduce the binaries to the ones selected by the given module list
#
sub prune_to_modules {
  my ($modules, $data, $bins) = @_;
  my %modules = map {$_ => 1} @{$modules || []};
  # expand modules to streams if we have the data
  my $moduleinfo = $data->{'/moduleinfo'};
  if ($moduleinfo) {
    my %pmodules = %modules;
    for (keys %pmodules) {
      $pmodules{$_} = 1 if /^(.*)-/;	# also provide without the stream suffix
    }
    my %xmodules;
    for my $mi (@$moduleinfo) {
      next unless $modules{$mi->{'name'}};
      my @req = grep {$_ ne 'platform' && !/^platform-/} @{$mi->{'requires'} || []};
      next if grep {!$pmodules{$_}} @req;
      $xmodules{"$mi->{'name'}\@$mi->{'context'}"} = 1;
    }
    %modules = %xmodules;
  }
  # now get rid of all packages not in a module
  my @nbins;
  my @notmod;
  my %inmod;
  for my $bin (@$bins) {
    my $evr = $bin->{'epoch'} ? "$bin->{'epoch'}:$bin->{'version'}" : $bin->{'version'};
    $evr .= "-$bin->{'release'}" if defined $bin->{'release'};
    my $nevra = "$bin->{'name'}-$evr.$bin->{'arch'}";
    if ($data->{$nevra}) {
      next unless grep {$modules{$_}} @{$data->{$nevra}};
      $inmod{$bin->{'name'}} = 1;
    } else {
      # not in a module
      next if $bin->{'release'} && $bin->{'release'} =~ /\.module_/;	# hey!
      push @notmod, $bin;
    }
    push @nbins, $bin;
  }
  for (@notmod) {
    $_ = undef if $inmod{$_->{'name'}};
  }
  @nbins = grep {defined($_)} @nbins;
  return \@nbins;
}

#
# return the modules a package belongs to
#
sub getmodules {
  my ($data, $bin) = @_;
  my $moduleinfo = $data->{'/moduleinfo'};
  my $evr = $bin->{'epoch'} ? "$bin->{'epoch'}:$bin->{'version'}" : $bin->{'version'};
  $evr .= "-$bin->{'release'}" if defined $bin->{'release'};
  my $nevra = "$bin->{'name'}-$evr.$bin->{'arch'}";
  return @{$data->{$nevra} || []};
}

#
# return which modules are missing from the module config
#
sub missingmodules {
  my ($modules, $data) = @_;
  my $moduleinfo = $data->{'/moduleinfo'};
  return () unless $moduleinfo && @{$modules || []};
  my %modules = map {$_ => 1} @$modules;
  my %pmodules = %modules;
  for (keys %pmodules) {
    $pmodules{$_} = 1 if /^(.*)-/;	# also provide without the stream suffix
  }
  my %missingmods;
  for my $mi (@$moduleinfo) {
    my $n = $mi->{'name'};
    next unless $modules{$n};
    next if exists($missingmods{$n}) && !$missingmods{$n};
    my @req = grep {$_ ne 'platform' && !/^platform-/} @{$mi->{'requires'} || []};
    my $bad;
    for (grep {!$pmodules{$_}} @req) {
      push @{$missingmods{$n}}, $_;
      $bad = 1;
    }
    $missingmods{$n} = undef unless $bad;
  }
  delete $missingmods{$_} for grep {!$missingmods{$_}} keys %missingmods;
  return undef unless %missingmods;
  my $msg = '';
  for my $mod (sort keys %missingmods) {
    my @m = sort(PBuild::Util::unify(@{$missingmods{$mod}}));
    if (@m > 1) {
      $msg .= ", $mod needs one of ".join(',', @m);
    } else {
      $msg .= ", $mod needs $m[0]";
    }
  }
  return substr($msg, 2);
}

1;
