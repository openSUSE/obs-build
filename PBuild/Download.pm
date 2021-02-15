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
use Digest::MD5 ();
use Digest::SHA ();

#
# Create a user agent used to access remote servers
#
sub create_ua {
  my $ua = LWP::UserAgent->new(agent => "openSUSE build script", timeout => 42, ssl_opts => { verify_hostname => 1 });
  $ua->env_proxy;
  return $ua;
}

#
# Create a hash context from a digest
#
sub digest2ctx {
  my ($digest) = @_;
  return Digest::SHA->new(1) if $digest =~ /^sha1?:/i;
  return Digest::SHA->new($1) if $digest =~ /^sha(\d+):/i;
  return Digest::MD5->new() if $digest =~ /^md5:/i;
  return undef;
}

#
# Verify that some data matches a digest
#
sub checkdigest {
  my ($data, $digest) = @_;
  my $ctx = digest2ctx($digest);
  die("unsupported digest algo '$digest'\n") unless $ctx;
  $ctx->add($data);
  my $hex = $ctx->hexdigest();
  if (lc($hex) ne lc((split(':', $digest, 2))[1])) {
    die("digest mismatch: $digest, got $hex\n");
  }
}

#
# Download data from a server
#
sub fetch {
  my ($url, %opt) = @_;
  my $ua = $opt{'ua'} || create_ua();
  my $retry = $opt{'retry'} || 0;
  my $res;
  my @accept;
  @accept = ('Accept', join(', ', @{$opt{'accept'}})) if $opt{'accept'};
  while (1) {
    $res = $ua->get($url, @accept, @{$opt{'headers'} || []});
    last if $res->is_success;
    return undef if $opt{'missingok'} && $res->code == 404;
    my $status = $res->status_line;
    die("download of $url failed: $status\n") unless $retry-- > 0 && $res->previous;
    warn("retrying $url\n");
  }
  my $data = $res->decoded_content;
  my $ct = $res->header('content_type');
  checkdigest($data, $opt{'digest'}) if $opt{'digest'};
  return ($data, $ct);
}

#
# Verify that the content of a file matches a digest
#
sub checkfiledigest {
  my ($file, $digest) = @_;
  my $ctx = digest2ctx($digest);
  die("$file: unsupported digest algo '$digest'\n") unless $ctx;
  my $fd;
  open ($fd, '<', $file) || die("$file: $!\n");
  $ctx->addfile($fd);
  close($fd);
  my $hex = $ctx->hexdigest();
  if (lc($hex) ne lc((split(':', $digest, 2))[1])) {
    die("$file: digest mismatch: $digest, got $hex\n");
  }
}

#
# Download a file from a server
#
sub download {
  my ($url, $dest, $destfinal, %opt) = @_;
  my $ua = $opt{'ua'} || create_ua();
  my $retry = $opt{'retry'} || 0;
  while (1) {
    unlink($dest);        # disable last-modified handling, always download
    my $res = $ua->mirror($url, $dest);
    last if $res->is_success;
    my $status = $res->status_line;
    die("download of $url failed: $status\n") unless $retry-- > 0 && $res->previous;
    warn("retrying $url\n");
  }
  checkfiledigest($dest, $opt{'digest'}) if $opt{'digest'};
  if ($destfinal) {
    rename($dest, $destfinal) || die("rename $dest $destfinal: $!\n");
  }
}

1;
