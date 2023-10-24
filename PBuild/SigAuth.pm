################################################################
#
# Copyright (c) 2022 SUSE LLC
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

package PBuild::SigAuth;

use MIME::Base64 ();

use strict;

our $key_id;
our $key_file;

sub dosshsign {
  my ($signdata, $keyfile, $namespace) = @_;
  die("no key file specified\n") unless $keyfile;
  my $fh;
  my $pid = open($fh, '-|');
  die("pipe open: $!\n") unless defined $pid;
  if (!$pid) {
    my $pid2 = open(STDIN, '-|');
    die("pipe open: $!\n") unless defined $pid2;
    if (!$pid2) {
      print STDOUT $signdata or die("write signdata: $!\n");
      exit 0;
    }
    exec('ssh-keygen', '-Y', 'sign', '-n', $namespace, '-f', $keyfile);
    die("ssh-keygen: $!\n");
  }
  my $out = '';
  1 while sysread($fh, $out, 8192, length($out));
  die("Signature authentification: bad ssh signature format\n") unless $out =~ s/.*-----BEGIN SSH SIGNATURE-----\n//s;
  die("Signature authentification: bad ssh signature format\n") unless $out =~ s/-----END SSH SIGNATURE-----.*//s;
  my $sig = MIME::Base64::decode_base64($out);
  die("Signature authentification: bad ssh signature\n") unless substr($sig, 0, 6) eq 'SSHSIG';
  return $sig;
}

sub generate_authorization {
  my ($auth_param, $keyid, $keyfile) = @_;
  my $realm = $auth_param->{'realm'} || '';
  my $headers = $auth_param->{'headers'} || '(created)';
  my $created = time();
  my $tosign = '';
  for my $h (split(/ /, $headers)) {
    if ($h eq '(created)') {
      $tosign .= "(created): $created\n";
    } else {
      die("Signature authentification: unsupported header element: $h\n");
    }
  }
  die("Signature authentification: no keyid specified\n") unless defined($keyid);
  die("Signature authentification: nothing to sign?\n") unless $tosign;
  chop $tosign;
  my $algorithm = $auth_param->{'algorithm'} || 'ssh';
  die("Signature authentification: unsupported algorithm '$algorithm'\n") unless $algorithm eq 'ssh';
  my $sig = dosshsign($tosign, $keyfile, $realm);
  $sig = MIME::Base64::encode_base64($sig, '');
  die("bad keyid '$keyid'\n") if $keyid =~ /\"/;
  return "Signature keyId=\"$keyid\",algorithm=\"$algorithm\",headers=\"$headers\",created=$created,signature=\"$sig\"";
}

sub get_key_data {
  my ($uri) = @_;
  my $keyid = $key_id;
  my $keyfile = $key_file;
  if (!defined($keyid)) {
    # check if the host includes a user name
    my $authority = $uri->authority;
    if ($authority =~ s/^([^\@]*)\@//) {
      $keyid = $1;
      $keyid =~ s/:.*//;	# ignore password
    }
  }
  if (!defined($keyfile)) {
    my $home = $ENV{'HOME'};
    if ($home && -d "$home/.ssh") {
      for my $idfile (qw{id_ed25519 id_rsa}) {
	next unless -s "$home/.ssh/$idfile";
	$keyfile = "$home/.ssh/$idfile";
	last;
      }
    }
  }
  return ($keyid, $keyfile);
}

sub authenticate {
  my ($class, $ua, $proxy, $auth_param, $response, $request, $arg, $size) = @_;
  my $uri = $request->uri_canonical;
  return $response unless $uri && !$proxy;
  my ($keyid, $keyfile) = get_key_data($uri);
  my $host_port = $uri->host_port;
  my $auth = generate_authorization($auth_param, $keyid, $keyfile);
  my $h = $ua->get_my_handler('request_prepare', 'm_host_port' => $host_port, sub {
    $_[0]{callback} = sub { $_[0]->header('Authorization' => $auth) };
  });
  return $ua->request($request->clone, $arg, $size, $response);
}

# install handler
no warnings;
*LWP::Authen::Signature::authenticate = \&authenticate;
