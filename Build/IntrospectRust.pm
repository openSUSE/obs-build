
package Build::IntrospectRust;

use strict;

use Build::ELF;
use Compress::Zlib ();

eval { require JSON::XS };
*JSON::XS::decode_json = sub {die("JSON::XS is not available\n")} unless defined &JSON::XS::decode_json;

sub rawversioninfo {
  my ($fh) = @_;
  my $elf = Build::ELF::readelf($fh);
  my ($off, $len);
  my $sect = $elf->findsect('.dep-v0') || $elf->findsect('rust-deps-v0');
  return undef unless $sect;
  my $comp_data = $elf->readsect($sect);
  my $data = Compress::Zlib::uncompress($comp_data);
  return $data;
}

sub versioninfo {
  my ($fh) = @_;
  my $data = rawversioninfo($fh);
  return undef unless $data;
  return JSON::XS::decode_json($data);
}

1;
