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

package PBuild::Container;

use Digest::MD5 ();

use PBuild::Util;
use PBuild::Verify;

eval { require JSON::XS };
*JSON::XS::decode_json = sub {die("JSON::XS is not available\n")} unless defined &JSON::XS::decode_json;

eval { require IO::Uncompress::Gunzip; };
*IO::Uncompress::Gunzip::new = sub {die("IO::Uncompress::Gunzip is not available\n")} unless defined &IO::Uncompress::Gunzip::new;

use strict;

sub manifest2obsbinlnk {
  my ($dir, $file, $prefix, $packid) = @_;
  my $json_fh;
  my $md5 = Digest::MD5->new;
  my $image;
  my $json_text = do {
      unless (open($json_fh, "<", "$dir/$file")) {
          warn("Error opening $dir/$file: $!\n");
          return {};
      }
      if ($file =~ /\.gz$/) {
        $json_fh = IO::Uncompress::Gunzip->new($json_fh) or die("Error opening $dir/$file: $IO::Uncompress::Gunzip::GunzipError\n");
      }
      local $/;
      <$json_fh>
  };

  my $metadata = JSON::XS::decode_json($json_text);
  if (!$metadata || !$metadata->{'config'}) {
    return {};
  }

  foreach my $ext ("", ".gz", ".xz", ".zst", ".zstd") {
    if (-e "$dir/$prefix$ext") {
      open(my $fh, '<', "$dir/$prefix$ext") or die("Error opening $dir/$prefix$ext: $!\n");
      $md5->addfile($fh);
      close($fh);
      $image = $prefix . $ext;
      last;
    }
  }
  if (!$image) {
    return {};
  }

  my $distribution = $metadata->{'config'}->{'distribution'};
  my $release = $metadata->{'config'}->{'release'};
  my $architecture = $metadata->{'config'}->{'architecture'};
  my $name = $metadata->{'config'}->{'name'};
  my $version = $metadata->{'config'}->{'version'};
  # Note: release here is not the RPM release, but the distribution release (eg: Debian 10)
  my @provides = ("$distribution:$release", "$name = $version", "$packid = $version");

  return {
      'provides' => \@provides,
      'source' => $packid,
      'name' => $name,
      'version' => $version,
      'release' => '0',
      'arch' => $architecture,
      'hdrmd5' => $md5->hexdigest(),
      'lnk' => $image,
  };
}

sub containerinfo2nevra {
  my ($d) = @_;
  my $lnk = {};
  $lnk->{'name'} = "container:$d->{'name'}";
  $lnk->{'version'} = defined($d->{'version'}) ? $d->{'version'} : '0';
  $lnk->{'release'} = defined($d->{'release'}) ? $d->{'release'} : '0';
  $lnk->{'arch'} = defined($d->{'arch'}) ? $d->{'arch'} : 'noarch';
  return $lnk;
}

sub containerinfo2obsbinlnk {
  my ($dir, $containerinfo, $packid) = @_;
  my $d = readcontainerinfo($dir, $containerinfo);
  return unless $d;
  my $lnk = containerinfo2nevra($d);
  # need to have a source so that it goes into the :full tree
  $lnk->{'source'} = $lnk->{'name'};
  # add self-provides
  push @{$lnk->{'provides'}}, "$lnk->{'name'} = $lnk->{'version'}";
  for my $tag (@{$d->{tags}}) {
    push @{$lnk->{'provides'}}, "container:$tag" unless "container:$tag" eq $lnk->{'name'};
  }
  eval { PBuild::Verify::verify_nevraquery($lnk) };
  return undef if $@;
  local *F;
  if ($d->{'tar_md5sum'}) {
    # this is a normalized container
    $lnk->{'hdrmd5'} = $d->{'tar_md5sum'};
    $lnk->{'lnk'} = $d->{'file'};
    return $lnk;
  }
  return undef unless open(F, '<', "$dir/$d->{'file'}");
  my $ctx = Digest::MD5->new;
  $ctx->addfile(*F);
  close F;
  $lnk->{'hdrmd5'} = $ctx->hexdigest();
  $lnk->{'lnk'} = $d->{'file'};
  return $lnk;
}

sub readcontainerinfo {
  my ($dir, $containerinfo) = @_;
  return undef unless -e "$dir/$containerinfo";
  return undef unless (-s _) < 100000;
  my $m = PBuild::Util::readstr("$dir/$containerinfo");
  my $d;
  eval { $d = JSON::XS::decode_json($m); };
  return undef unless $d && ref($d) eq 'HASH';
  my $tags = $d->{'tags'};
  $tags = [] unless $tags && ref($tags) eq 'ARRAY';
  for (@$tags) {
    $_ = undef unless defined($_) && ref($_) eq '';
  }
  @$tags = grep {defined($_)} @$tags;
  my $name = $d->{'name'};
  $name = undef unless defined($name) && ref($name) eq '';
  if (!defined($name) && @$tags) {
    # no name specified, get it from first tag
    $name = $tags->[0];
    $name =~ s/[:\/]/-/g;
  }
  $d->{name} = $name;
  my $file = $d->{'file'};
  $d->{'file'} = $file = undef unless defined($file) && ref($file) eq '';
  delete $d->{'disturl'} unless defined($d->{'disturl'}) && ref($d->{'disturl'}) eq '';
  delete $d->{'buildtime'} unless defined($d->{'buildtime'}) && ref($d->{'buildtime'}) eq '';
  delete $d->{'imageid'} unless defined($d->{'imageid'}) && ref($d->{'imageid'}) eq '';
  return undef unless defined($name) && defined($file);
  eval {
    PBuild::Verify::verify_simple($file);
    PBuild::Verify::verify_filename($file);
  };
  return undef if $@;
  return $d;
}

1;
