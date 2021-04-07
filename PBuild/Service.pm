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

package PBuild::Service;

use strict;

use PBuild::Util;
use PBuild::Structured;

my $dtd_services = [
    'services' =>
     [[ 'service' =>
            'name',
            'mode', # "localonly" is skipping this service on server side, "trylocal" is trying to merge changes directly in local files, "disabled" is just skipping it
         [[ 'param' =>
                'name',
                '_content'
         ]],
    ]],
];

#
# Parse a _service file from a package
#
sub parse_service {
  my ($p) = @_;
  return undef unless $p->{'files'}->{'_service'};
  return PBuild::Structured::readxml("$p->{'dir'}/_service", $dtd_services, 1, 1);
}

#
# return the buildtime services of a package
#
sub get_buildtimeservices {
  my ($p) = @_;
  return [] unless $p->{'files'}->{'_service'};
  my @bt;
  my $services = parse_service($p);
  for my $service (@{$services->{'service'} || []}) {
    push @bt, $service->{'name'} if ($service->{'mode'} || '') eq 'buildtime';
  }
  return sort(PBuild::Util::unify(@bt));
}

1;
