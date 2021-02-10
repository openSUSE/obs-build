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

package PBuild::Download;

use strict;

use LWP::UserAgent;
use URI;
use Digest::MD5 ();
use Digest::SHA ();

sub create_ua {
  my $ua = LWP::UserAgent->new(agent => "openSUSE build script", timeout => 42, ssl_opts => { verify_hostname => 1 });
  $ua->env_proxy;
  return $ua;
}

sub checkdigest {
  my ($file, $digest) = @_;
  my $ctx;
  if ($digest =~ /^sha1?:/i) {
    $ctx = Digest::SHA->new(1);
  } elsif ($digest =~ /^sha(\d+):/i) {
    $ctx = Digest::SHA->new($1);
  } elsif ($digest =~ /^md5:/i) {
    $ctx = Digest::MD5->new();
  }
  die("$file unsupported digest algo '$digest'\n") unless $ctx;
  my $fd;
  open ($fd, '<', $file) || die("$file: $!\n");
  $ctx->addfile($fd);
  close($fd);
  my $hex = $ctx->hexdigest();
  if (lc($hex) ne lc((split(':', $digest, 2))[1])) {
    die("$file: digest mismatch: $digest, got $hex\n");
  }
}

sub download {
  my ($url, $dest, $destfinal, $digest, $ua, $retry) = @_;
  $ua ||= create_ua();
  $retry ||= 0;
  while (1) {
    unlink($dest);        # just in case
    my $res = $ua->mirror($url, $dest);
    last if $res->is_success;
    my $status = $res->status_line;
    die("download of $url failed: $status\n") unless $retry >= 0 && $res->previous;
    warn("retrying $url\n");
    $retry--;
  }
  checkdigest($dest, $digest) if $digest;
  if ($destfinal) {
    rename($dest, $destfinal) || die("rename $dest $destfinal: $!\n");
  }
}

1;
