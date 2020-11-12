#!/usr/bin/perl
use strict;
use warnings;

use FindBin '$Bin';
use Test::More 0.98;

my $path = "$Bin/data";
use Build;
use Build::Flatpak;

my $conf = Build::read_config('x86_64');

sub capture_stdout {
  my ($fn) = @_;
  local *STDOUT;
  open(STDOUT, '>', \my $cap) || die;
  $fn->();
  return $cap;
}

subtest parse => sub {
    my $expected = {
        name => 'org.gnome.Chess',
        version => 0,
        sources => [
            "phalanx-XXV-source.tgz",
            "stockfish-10-src.zip",
            "gnuchess-6.2.5.tar.gz",
            "gnome-chess-3.36.1.tar.xz",
        ],
        deps => [
            'org.gnome.Sdk-v3.36',
            'org.gnome.Platform-v3.36',
        ],
    };
    my $data = Build::Flatpak::parse($conf, "$FindBin::Bin/fixtures/flatpak.yml");
    is_deeply $data, $expected, 'parse() YAML flatpak content';

    $data = Build::Flatpak::parse($conf, "$path/flatpak.yaml");
    is_deeply $data, $expected, 'parse() YAML flatpak file';

    $data = Build::Flatpak::parse($conf, "$path/flatpak.json");
    is_deeply $data, $expected, 'parse() JSON flatpak file';
};

subtest show => sub {
    local @ARGV = ("$path/flatpak.yaml", 'name');
    my $data = capture_stdout(sub { Build::Flatpak::show() });
    is $data, "org.gnome.Chess\n", 'Build::Flatpak::show name';
};

done_testing;
