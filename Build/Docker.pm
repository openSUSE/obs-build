################################################################
#
# Copyright (c) 2017 SUSE Linux Products GmbH
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

# TODO:
# - parse Dockerfile and extract dependecies
# - start docker daemon
# - import base image to the docker daemon
# - setup the dependencies directory
# - setup a zypper repository that will serve the dependecies directory
# - inject this repository as and ARG in the Dockerfile
# - build the Dockerfile
# - export the image tarball [OPTIONAL]

package Build::Dockerimage;

use strict;

sub parse {
  my ($cf, $fn) = @_;

  # Perl slurp mode
  local $/=undef;
  open DOCKERFILE, $fn or die "Couldn't open Dockefile";
  my $dockerfile_data = <DOCKERFILE>;
  close DOCKERFILE;

  # Remove all whitespace from end of lines to make parsing easier
  $dockerfile_data =~ s/[^\S\n\r]+$//gm;

  my @deps = ();
  my $pkg_string;

  # Match from start of line until an end of line which doesn't have a backslash
  # as the last character (Negative lookbehind).
  # That would mean, continue to the next line. E.g.
  # RUN obs_install package1 package2 \
  #   package3
  while ($dockerfile_data =~ /^\s*RUN\s+obs_install\s+((.|\n|\r)*?)(?<!\\)$/gm) {
    $pkg_string = $1;

    # Remove the Dockerfile escape character and merge multiple lines in one
    $pkg_string =~ s/\\(\n|\r)*//gm;

    # Make sure we only match obs_install arguments and not any commands that
    # follow. E.g.
    # RUN obs_install vim && do_something_else
    $pkg_string =~ s/(.*?)[;&].*/$1/;

    my @packages = split(/\s+/, $pkg_string);
    if (0+@packages != 0) { push @deps, @packages; }
  }

  print STDERR "Dependencies: @deps \n";

  my $ret = {};
  $ret->{'deps'} = \@deps;

  return $ret;
}

1;
