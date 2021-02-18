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

package PBuild::Link;

use strict;

use PBuild::Structured;
use PBuild::Util;

my $dtd_link = [
    'link' =>
        'project',
        'package',
        'baserev',
        'missingok',
      [ 'patches' => [[ '' => [] ]] ],
];

sub expand_single_link {
  my ($pkgs, $pkg) = @_;
  my @todo = ($pkg);
  while (@todo) {
    my $pkg = shift @todo;
    my $p = $pkgs->{$pkg};
    next if $p->{'error'} && $p->{'error'} =~ /^link expansion:/;
    my $files = $p->{'files'} || {};
    next unless $files->{'_link'};
    my $link = PBuild::Structured::readxml("$p->{'dir'}/_link", $dtd_link, 1, 1);
    if (!defined($link)) {
      $p->{'error'} = 'link expansion: bad _link xml';
      next;
    }
    if (exists $link->{'project'}) {
      $p->{'error'} = 'link expansion: only local links allowed';
      next;
    }
    if (!$link->{'package'}) {
      $p->{'error'} = 'link expansion: no package attribute';
      next;
    }
    if ((exists($link->{'patches'}) && exists($link->{'patches'}->{''})) || keys(%$files) != 1) {
      $p->{'error'} = 'link expansion: only simple links supported';
      next;
    }
    my $tpkg = $link->{'package'};
    my $tp = $pkgs->{$tpkg};
    if (!$tp) {
      $p->{'error'} = "link expansion: target package '$tpkg' does not exist";
      next;
    }
    if ($tp->{'error'} && $tp->{'error'} =~ /^link expansion:(.*)/) {
      $p->{'error'} = "link expansion: $tpkg: $1";
      $p->{'error'} = "link expansion: $1" if $1 eq 'cyclic link';
      next;
    }
    if (($tp->{'files'} || {})->{'_link'}) {
      if (grep {$_ eq $tpkg} @todo) {
        $p->{'error'} = "link expansion: cyclic link";
      } else {
        unshift @todo, $tpkg, $pkg;
      }
      next;
    }
    $pkgs->{$pkg} = { %$tp, 'pkg' => $pkg };
  }
}

sub expand_links {
  my ($pkgs) = @_;
  for my $pkg (sort keys %$pkgs) {
    my $p = $pkgs->{$pkg};
    my $files = $p->{'files'} || {};
    expand_single_link($pkgs, $pkg) if $files->{'_link'};
  }
}

1;
