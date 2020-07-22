################################################################
#
# Copyright (c) 2020 SUSE Linux Products GmbH
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

package Build::Helm;

use strict;

use Build::SimpleJSON;
use Data::Dumper;
eval { require YAML::XS; };
*YAML::XS::LoadFile = sub {die("YAML::XS is not available\n")} unless defined &YAML::XS::LoadFile;

sub makeconfigjson {
  my ($fn) = @ARGV;

  my $configjson;
  eval {$configjson = YAML::XS::LoadFile($fn);};

  #$chartinfo->{'file'} = "$sha.tar";

  print Build::SimpleJSON::unparse($configjson)."\n";
}

sub makemanifestjson {
  my ($configsha, $repotags, $layers) = @ARGV;
  my @repotags = split(',', $repotags);
  my @layers = split(',', $layers);

  my %manifest;
  $manifest{Config} = $configsha;
  $manifest{Repotags} = \@repotags;
  $manifest{Layers} = \@layers;

  # this is small c(config), we are (ab)using json's case sensitive keys.
  my @s = stat($configsha) if -e $configsha;
  $manifest{config} = {
      "mediaType" => "application/vnd.cncf.helm.config.v1+json",
      "digest" => $configsha,
      "size" => @s[7],
  };

  # this is small l(layers), we are (ab)using json's case sensitive keys.
  my @digestedlayers;
  for my $lay (@layers) {
      #next unless -e $lay;
      #@s = stat($lay);
      my $layer_data =  {
          "mediaType" => "application/tar+gzip",
          "digest" => $lay,
          #"size" => \@s[7],
      };
      push @digestedlayers, $layer_data;
  }

  $manifest{layers} = \@digestedlayers;

  print Build::SimpleJSON::unparse([\%manifest])."\n";

}

sub makecontainerinfo {
  my ($file, $repotags, $version) = @ARGV;

  my $buildtime = time();
  my $containerinfo = {
    'buildtime' => $buildtime,
    '_type' => {'buildtime' => 'number'},
  };

  my @repotags = split(',', $repotags);
  $containerinfo->{'tags'} = \@repotags;
  #$containerinfo->{'repos'} = \@repos if @repos;
  $containerinfo->{'file'} = $file;
  #$containerinfo->{'disturl'} = $disturl if defined $disturl;
  $containerinfo->{'version'} = $version;
  $containerinfo->{'release'} = $version;
  print Build::SimpleJSON::unparse($containerinfo)."\n";
}



sub chartdetails {
  my ($fn) = @ARGV;
  my $chartinfo;
  eval {$chartinfo = YAML::XS::LoadFile($fn);};

  #print Dumper($chartinfo);
  print "name:";
  print $chartinfo->{"name"};
  print "\n";

  print "version:";
  print $chartinfo->{"version"};
  print "\n";
}
