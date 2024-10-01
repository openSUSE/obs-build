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

# simple anon bearer authenticator

package PBuild::BearerAuth;

use strict;

use LWP::UserAgent;
use URI;

eval { require JSON::XS };
*JSON::XS::decode_json = sub {die("JSON::XS is not available\n")} unless defined &JSON::XS::decode_json;

# 
sub bearer_authenticate {
  my($class, $ua, $proxy, $auth_param, $response, $request, $arg, $size) = @_;
  return $response if $ua->{'bearer_authenticate_norecurse'};
  local $ua->{'bearer_authenticate_norecurse'} = 1;
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
  return $response unless $ares->is_success;
  my $reply = JSON::XS::decode_json($ares->decoded_content);
  my $token = $reply->{'token'} || $reply->{'access_token'};
  return $response unless $token;
  my $url = $proxy ? $request->{proxy} : $request->uri_canonical;
  my $host_port = $url->host_port;
  my $h = $ua->get_my_handler('request_prepare', 'm_host_port' => $host_port, sub {
    $_[0]{callback} = sub { $_[0]->header('Authorization' => "Bearer $token") };
  });
  return $ua->request($request->clone, $arg, $size, $response);
}

# install handler
no warnings;
*LWP::Authen::Bearer::authenticate = \&bearer_authenticate;

1;
