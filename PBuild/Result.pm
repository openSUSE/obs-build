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

package PBuild::Result;

use strict;

use PBuild::Util;

my @code_order = qw{broken succeeded failed unresolvable blocked scheduled waiting building excluded disabled locked};
my %code_failures = map {$_ => 1} qw{broken failed unresolvable};

sub print_result {
  my ($opts, $builddir) = @_;
  my $r = PBuild::Util::retrieve("$builddir/.pbuild/_result");
  die("pbuild has not run yet for $builddir\n") unless $r;
  my %codefilter = map {$_ => 1} @{$opts->{'result-code'} || []};
  my %pkgfilter = map {$_ => 1} @{$opts->{'result-pkg'} || []};
  my $found_failures = 0;
  my %codes_seen;
  for my $pkg (sort keys %$r) {
    next if %pkgfilter && !$pkgfilter{$pkg};
    my $code = $r->{$pkg}->{'code'} || 'unknown';
    $found_failures = 1 if $code_failures{$code};
    next if %codefilter && !$codefilter{'all'} && !$codefilter{$code};
    push @{$codes_seen{$code}}, $pkg;
  }
  my @codes_seen;
  for (@code_order) {
    push @codes_seen, $_ if $codes_seen{$_};
  }
  @codes_seen = PBuild::Util::unify(@codes_seen, sort keys %codes_seen);
  for my $code (@codes_seen) {
    my $ncode = @{$codes_seen{$code}};
    printf "%-10s %d\n", "$code:", $ncode;
    next if ($code eq 'disabled' || $code eq 'excluded') && !$codefilter{$code};
    next unless $opts->{'result-code'} || $opts->{'result-pkg'};
    for my $pkg (@{$codes_seen{$code}}) {
      if ($opts->{'result-details'}) {
	my $details = $r->{$pkg}->{'details'};
	if ($details) {
          print "    $pkg ($details)\n";
	} else {
          print "    $pkg\n";
	}
      } else {
        print "    $pkg\n";
      }
    }
  }
  return $found_failures;
}

1;
