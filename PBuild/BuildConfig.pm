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

package PBuild::BuildConfig;

sub combineconfigs {
  my (@c) = @_;
  my $config = '';
  my $macros = '';
  for my $c (@c) {
    $c =~ s/\n?$/\n/s if $c ne '';
    if ($c =~ /^\s*:macros\s*$/im) {
      # probably some multiple macro sections with %if statements
      # flush out macros
      $config .= "\nMacros:\n$macros:Macros\n\n" if $macros ne '';
      $macros = '';
      my $s1 = '\A(.*^\s*:macros\s*$)(.*?)\Z';  # should always match
      if ($c =~ /$s1/msi) {
        $config .= $1;
        $c = $2;
      } else {
        $config .= $c;
        $c = '';
      }
    }
    if ($c =~ /^(.*\n)?\s*macros:[^\n]*\n(.*)/si) {
      # has single macro section at end. cumulate
      $c = defined($1) ? $1 : '';
      $macros .= $2;
    }
    $config .= $c;
  }
  $config .= "\nMacros:\n$macros" if $macros ne '';
  return $config;
}

1;
