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

package Build::Options;

use strict;

sub getarg {
  my ($origopt, $args, $optional) = @_;
  return ${shift @$args} if @$args && ref($args->[0]);
  return shift @$args if @$args && $args->[0] !~ /^-/;
  die("Option $origopt needs an argument\n") unless $optional;
  return undef;
}

sub parse_options {
  my ($known_options, @args) = @_;
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
    my $ko = $known_options->{$opt};
    die("Unknown option '$origopt'. Exit.\n") unless defined $ko;
    $ko = "$opt$ko" if !ref($ko) && ($ko eq '' || $ko =~ /^:/);
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
      my $arg = 1;
      if (@args && ref($args[0])) {
        $arg = getarg($origopt, \@args);
	$arg = 0 if $arg =~ /^(?:0|off|false|no)$/i;
	$arg = 1 if $arg =~ /^(?:1|on|true|yes)$/i;
	die("Bad boolean argument for option $origopt: '$arg'\n") unless $arg eq '0' || $arg eq '1';
      }
      $opts{$ko} = $arg;
    }
    die("Option $origopt does not take an argument\n") if @args && ref($args[0]);
  }

  return (\%opts, @back);
}

1;
