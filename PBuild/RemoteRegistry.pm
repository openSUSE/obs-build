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

package PBuild::RemoteRegistry;

use strict;

use LWP::UserAgent;
use URI;

use PBuild::Verify;
use PBuild::Download;
use Build::SimpleJSON;

eval { require JSON::XS };
*JSON::XS::decode_json = sub {die("JSON::XS is not available\n")} unless defined &JSON::XS::decode_json;

#
# mime types
#
my $mt_docker_manifest     = 'application/vnd.docker.distribution.manifest.v2+json';
my $mt_docker_manifestlist = 'application/vnd.docker.distribution.manifest.list.v2+json';
my $mt_oci_manifest        = 'application/vnd.oci.image.manifest.v1+json';
my $mt_oci_index           = 'application/vnd.oci.image.index.v1+json';

# 
# simple anon bearer authenticator
# 
sub bearer_authenticate {
  my($class, $ua, $proxy, $auth_param, $response, $request, $arg, $size) = @_;
  my $realm = $auth_param->{'realm'};
  die("bearer auth did not provide a realm\n") unless $realm;
  die("bearer realm is not http/https\n") unless $realm =~ /^https?:\/\//i;
  my $auri = URI->new($realm);
  my @afields;
  for ('service', 'scope') {
    push @afields, $_, $auth_param->{$_} if defined $auth_param->{$_};
  }
  print "requesting bearer auth from $realm [@afields]\n";
  $auri->query_form($auri->query_form, @afields);
  my $ares = $ua->get($auri);
  return $request unless $ares->is_success;
  my $reply = JSON::XS::decode_json($ares->decoded_content);
  my $token = $reply->{'token'} || $reply->{'access_token'};
  return $request unless $token;
  my $url = $proxy ? $request->{proxy} : $request->uri_canonical;
  my $host_port = $url->host_port;
  my $h = $ua->get_my_handler('request_prepare', 'm_host_port' => $host_port, sub {
    $_[0]{callback} = sub { $_[0]->header('Authorization' => "Bearer $token") };
  });
  return $ua->request($request->clone, $arg, $size, $response);
}

*LWP::Authen::Bearer::authenticate = \&bearer_authenticate;

#
# convert arch to goarch/govariant
#
sub arch2goarch {
  my ($arch) = @_;
  return ('amd64') if $arch eq 'x86_64';
  return ('386') if $arch =~ /^i[3456]86$/;
  return ('arm64', 'v8') if $arch eq 'aarch64';
  return ('arm', "v$1") if $arch =~ /^armv(\d+)/;
  return $arch;
}

#
# select a matching manifest from a manifest index (aka fat manifest)
#
sub select_manifest {
  my ($arch, $manifests) = @_;
  my ($goarch, $govariant) = arch2goarch($arch);
  for my $m (@{$manifests || []}) {
    next unless $m->{'digest'};
    if ($m->{'platform'}) {
      next if $m->{'platform'}->{'architecture'} ne $goarch;
      next if $m->{'platform'}->{'variant'} && $govariant && $m->{'platform'}->{'variant'} ne $govariant;
    }
    return $m;
  }
  return undef;
}

#
# query a registry about a container
#
sub queryremotecontainer {
  my ($ua, $arch, $registry, $repotag) = @_;
  $repotag .= ":latest" unless $repotag =~ /:[^\/:]+$/;
  die unless $repotag =~ /^(.*):([^\/:]+)$/;
  my ($repository, $tag) = ($1, $2);
  $repository = "library/$repository" if $repository !~ /\// && $registry =~ /docker.io\/?$/;

  my @accept = ($mt_docker_manifestlist, $mt_docker_manifest, $mt_oci_index, $mt_oci_manifest);
  my ($data, $ct) = PBuild::Download::fetch("$registry/v2/$repository/manifests/$tag",
	'ua' => $ua, 'accept' => \@accept, 'missingok' => 1);
  return undef unless defined $data;
  die("no content type set in answer\n") unless $ct;
  if ($ct eq $mt_docker_manifestlist || $ct eq $mt_oci_index) {
    # fat manifest, select the one we want
    my $r = JSON::XS::decode_json($data);
    my $manifest = select_manifest($arch, $r->{'manifests'} || []);
    return undef unless $manifest;
    @accept = ($mt_docker_manifest, $mt_oci_manifest);
    ($data, $ct) = PBuild::Download::fetch("$registry/v2/$repository/manifests/$manifest->{'digest'}",
	'ua' => $ua, 'accept' => \@accept);
    die("no content type set in answer\n") unless $ct;
  }
  die("unknown content type\n") unless $ct eq $mt_docker_manifest || $ct eq $mt_oci_manifest;
  my $r = JSON::XS::decode_json($data);
  my @blobs;
  die("manifest has no config\n") unless $r->{'config'};
  push @blobs, $r->{'config'};
  push @blobs, @{$r->{'layers'} || []};
  PBuild::Verify::verify_digest($_->{'digest'}) for @blobs;
  my $id = $blobs[0]->{'digest'};
  $id =~ s/.*://;
  $id = substr($id, 0, 32);
  my $name = $repotag;
  $name =~ s/[:\/]/-/g;
  $name = "container:$name";
  my $version = 0;
  my @provides = ("$name = $version");
  push @provides, "container:$repotag" unless $name eq "container:$repotag";
  my $q = {
    'name' => $name,
    'version' => $version,
    'arch' => 'noarch',
    'source' => $name,
    'provides' => \@provides,
    'hdrmd5' => $id,
    'location' => $repository,
    'blobs' => \@blobs,
    'containertags' => [ $repotag ],
  };
  return $q;
}

#
# get data from a registry for a set of containers
#
sub fetchrepo {
  my ($bconf, $arch, $repodir, $url, $repotags) = @_;
  my @bins;
  my $ua = PBuild::Download::create_ua();
  for my $repotag (@{$repotags || []}) {
    my $bin = queryremotecontainer($ua, $arch, $url, $repotag);
    push @bins, $bin if $bin;
  }
  return \@bins;
}

#
# download the blobs needed to reconstruct a container
#
sub fetchbinaries {
  my ($repo, $bins) = @_;
  my $repodir = $repo->{'dir'};
  my $url = $repo->{'url'};
  my $nbins = @$bins;
  die("bad repo\n") unless $url;
  my %tofetch;
  for my $bin (@$bins) {
    my $blobs = $bin->{'blobs'};
    die unless $blobs;
    for my $blob (@$blobs) {
      my $digest = $blob->{'digest'};
      die unless $digest;
      next if -s "$repodir/blob.$digest";
      $tofetch{"$bin->{'location'}/$digest"} = 1;
    }
  }
  return unless %tofetch;
  my @tofetch = sort keys %tofetch;
  my $ntofetch = @tofetch;
  print "fetching $ntofetch container blobs from $url\n";
  my $ua = PBuild::Download::create_ua();
  PBuild::Util::mkdir_p($repodir);
  for my $tofetch (@tofetch) {
    next unless $tofetch =~ /^(.*)\/(.*)?$/;
    my ($repository, $digest) = ($1, $2);
    next if -s "$repodir/blob.$digest";
    PBuild::Download::download("$url/v2/$repository/blobs/$digest", "$repodir/.blob.$digest.$$", "$repodir/blob.$digest", 'digest' => $digest, 'ua' => $ua);
  }
}

#
# create the head/pad data for a tar file entry
#
sub maketarhead {
  my ($name, $size, $mtime) = @_;

  my $h = "\0\0\0\0\0\0\0\0" x 64;
  my $pad = '';
  return ("$h$h") unless defined $name;
  my $tartype = '0';
  die("name too big\n") if length($name) > 100;
  my $mode = sprintf("%07o", 0x81a4);
  my $fsize = sprintf("%011o", $size);
  my $fmtime = sprintf("%011o", $mtime);
  substr($h, 0, length($name), $name);
  substr($h, 100, length($mode), $mode);
  substr($h, 108, 15, "0000000\0000000000");    # uid/gid
  substr($h, 124, length($fsize), $fsize);
  substr($h, 136, length($fmtime), $fmtime);
  substr($h, 148, 8, '        ');
  substr($h, 156, 1, $tartype);
  substr($h, 257, 8, "ustar\00000");            # magic/version
  substr($h, 329, 15, "0000000\0000000000");    # major/minor
  substr($h, 148, 7, sprintf("%06o\0", unpack("%16C*", $h)));
  $pad = "\0" x (512 - $size % 512) if $size % 512;
  return ($h, $pad);
}

#
# reconstruct a container from blobs
#
sub construct_containertar {
  my ($repodir, $q, $dst) = @_;
  die("construct_containertar: $q->{'name'}: not a container\n") unless $q->{'name'} =~ /^container:/;
  my $fd;
  open ($fd, '>', $dst) || die("$dst: $!\n");
  my $mtime = time();
  my $blobs = $q->{'blobs'};
  die unless $blobs;
  for my $blob (@$blobs) {
    my $digest = $blob->{'digest'};
    die unless $digest;
    my $bfd;
    open ($bfd, '<', "$repodir/blob.$digest") || die("$repodir/blob.$digest: $!\n");
    my @s = stat($bfd);
    die unless @s;
    my $size = $s[7];
    my ($head, $pad) = maketarhead($digest, $size, $mtime);
    print $fd $head;
    while ($size > 0) {
      my $chunk = $size > 16384 ? 16384 : $size;
      my $b = '';
      die("unexpected read error in blob\n") unless sysread($bfd, $b, $chunk);
      print $fd $b;
      $size -= length($b);
    }
    print $fd $pad;
    close($bfd);
  }
  my @digests = map {$_->{'digest'}} @$blobs;
  my $configdigest = shift @digests;
  my $manifest = {
    'Config' => $configdigest,
    'Layers' => \@digests,
    'RepoTags' => $q->{'containertags'},
    '_order' => [ 'Config', 'RepoTags', 'Layers' ],
  };
  my $manifest_json = Build::SimpleJSON::unparse([ $manifest ], 'ugly' => 1);
  my ($head, $pad) = maketarhead('manifest.json', length($manifest_json), $mtime);
  print $fd "$head$manifest_json$pad".maketarhead();
  close($fd) || die;
}

1;
