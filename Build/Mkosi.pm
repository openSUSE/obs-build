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
  if (length $cfg->val('Partitions', 'BaseImage')) {
    push(@packages, $cfg->val('Partitions', 'BaseImage'));
  }

  $ret->{'name'} = $fn;
  $ret->{'deps'} = \@packages;

  return $ret;
}

sub queryiso {
  my ($file, %opts) = @_;
  my $json_fh;
  my $md5 = Digest::MD5->new;

  open(my $fh, '<', $file) or die("Error opening $file: $!\n");
  $md5->addfile($fh);
  close($fh);
  # If we also have split verity artifacts, the manifest file is the same as the main image,
  # so remove the suffixes to find it
  $file =~ s/(\.root|\.usr)//g;
  $file = $file . ".manifest.gz";

  eval { require JSON; };
  *JSON::decode_json = sub {die("JSON::decode_json is not available\n")} unless defined &JSON::decode_json;

  eval { require IO::Uncompress::Gunzip; };
  *IO::Uncompress::Gunzip::new = sub {die("IO::Uncompress::Gunzip is not available\n")} unless defined &IO::Uncompress::Gunzip::new;

  my $json_text = do {
      open($json_fh, "<", $file) or die("Error opening $file: $!\n");
      $json_fh = IO::Uncompress::Gunzip->new($json_fh) or die("Error opening $file: $IO::Uncompress::Gunzip::GunzipError\n");
      local $/;
      <$json_fh>
  };

  my $metadata = JSON::decode_json($json_text);
  close $json_fh;

  if (!$metadata || !$metadata->{'config'}) {
    return {};
  }

  my $distribution = $metadata->{'config'}->{'distribution'};
  my $release = $metadata->{'config'}->{'release'};
  my $architecture = $metadata->{'config'}->{'architecture'};
  my $name = $metadata->{'config'}->{'name'};
  my $version = $metadata->{'config'}->{'version'};
  my @provides = ("$distribution:$release");

  return {
      'provides' => \@provides,
      'version' => $version,
      'arch' => $architecture,
      'name' => $name,
      'source' => $name,
      'hdrmd5' => $md5->hexdigest(),
  };
}

sub queryhdrmd5 {
  my ($bin) = @_;

  open(my $fh, '<', $bin) or croak("could not open $bin");
  my $md5 = Digest::MD5->new;
  $md5->addfile($fh);
  close($fh);

  return $md5->hexdigest();
}

1;
