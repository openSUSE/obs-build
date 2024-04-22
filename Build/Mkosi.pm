#
# mkosi specific functions.
#
################################################################
#
# Copyright (c) 2022 Luca Boccassi <bluca@debian.org>
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

package Build::Mkosi;

use strict;

eval { require Config::IniFiles; };
*Config::IniFiles::new = sub {die("Config::IniFiles is not available\n")} unless defined &Config::IniFiles::new;

sub parse {
  my ($bconf, $fn) = @_;
  my $ret = {};
  my $file_content = "";

  open my $fh, "<", $fn;
  unless($fn) {
    warn("Cannot open $fn\n");
    $ret->{'error'} = "Cannot open $fn\n";
    return $ret;
  }

  # mkosi supports multi-value keys, separated by newlines, so we need to mangle the file
  # in order to make Config::IniFiles happy.
  # Remove the previous newline if the next line doesn't have a '=' or '[' character.
  while( my $line = <$fh>) {
    $line =~ s/#.*$//;
    if ((index $line, '=') == -1 && (index $line, '[') == -1) {
      chomp $file_content;
    }
    $file_content .= $line;
  }

  close $fh;

  my $cfg = Config::IniFiles->new( -file => \$file_content );
  unless($cfg) {
    warn("$fn: " . @Config::IniFiles::errors ? ":\n@Config::IniFiles::errors\n" : "\n");
    $ret->{'error'} = "$fn: " . @Config::IniFiles::errors ? ":\n@Config::IniFiles::errors\n" : "\n";
    return $ret;
  }

  my @packages;
  if (length $cfg->val('Content', 'Packages')) {
    push(@packages, split /\s+/, $cfg->val('Content', 'Packages'));
  }
  if (length $cfg->val('Content', 'BuildPackages')) {
    push(@packages, split /\s+/, $cfg->val('Content', 'BuildPackages'));
  }
  # XXX: split by comma
  if (length $cfg->val('Content', 'BaseTrees')) {
    push(@packages, "mkosi:".$cfg->val('Content', 'BaseTrees'));
  }

  $ret->{'name'} = $fn;
  $ret->{'deps'} = \@packages;

  return $ret;
}

1;
