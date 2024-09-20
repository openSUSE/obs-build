################################################################ #
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

package PBuild::Mkosi;

use Digest::MD5 ();
use IO::Uncompress::Gunzip ();

use PBuild::Verify;

eval { require JSON::XS };
*JSON::XS::decode_json = sub {die("JSON::XS is not available\n")} unless defined &JSON::XS::decode_json;

use strict;

sub read_manifest_json {
  my ($fn) = @_;
  my $json_fh;
  if (!open($json_fh, '<', $fn)) {
    warn("Error opening $fn: $!\n");
    return undef;
  }
  if ($fn =~ /\.gz$/) {
    $json_fh = IO::Uncompress::Gunzip->new($json_fh) or die("Error opening $fn: $IO::Uncompress::Gunzip::GunzipError\n");
  }
  local $/;
  return scalar(<$json_fh>);
}

sub manifest2obsbinlnk {
  my ($dir, $file, $prefix, $packid) = @_;
  my $json_text = read_manifest_json("$dir/$file");
  return unless $json_text;
  my $metadata = eval { JSON::XS::decode_json($json_text) };
  return unless $metadata && $metadata->{'config'} && ref($metadata->{'config'}) eq 'HASH';

  my $image;
  for my $ext ("", ".raw", ".gz", ".xz", ".zst", ".zstd") {
    my $fn = "$dir/$prefix$ext";
    if (-e $fn) {
      if (-l $fn) {
        $prefix = readlink($fn);
	$prefix =~ s/.*\///;
      }
      $image = $prefix . $ext;
      last
    }
  }
  return unless $image;
  eval {  PBuild::Verify::verify_filename($image) };
  return undef if $@;

  open(my $fh, '<', "$dir/$image") or die("Error opening $dir/$image: $!\n");
  my $md5 = Digest::MD5->new;
  $md5->addfile($fh);
  close($fh);

  my $config = $metadata->{'config'};
  my $distribution = $config->{'distribution'};
  my $distrelease = $config->{'release'};	# distribution release (eg: Debian 10)
  my $architecture = $config->{'architecture'};
  my $name = $config->{'name'};
  my $version = $config->{'version'} || '0';
  my $release = '0';
  my @provides = ("mkosi:$distribution:$distrelease", "mkosi:$name = $version-$release");

  my $lnk = {
    'name' => "mkosi:$name",
    'version' => $version,
    'release' => $release,
    'arch' => 'noarch',
    'provides' => \@provides,
    'source' => $packid,
  };
  eval { PBuild::Verify::verify_nevraquery($lnk) };
  return undef if $@;
  
  $lnk->{'hdrmd5'} = $md5->hexdigest();
  $lnk->{'lnk'} = $image;
  return $lnk;
}

1;
