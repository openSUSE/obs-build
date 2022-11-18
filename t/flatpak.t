#!/usr/bin/perl
use strict;
use warnings;

use FindBin '$Bin';
use Test::More 0.98;

my $path = "$Bin/data";
use Build;
use Build::Flatpak;

my $rewritten_manifest = do {
    local $/;
    open my $fh, '<', "$Bin/data/flatpak-rewritten.yaml" or die $!;
    <$fh>;
};
my $conf = Build::read_config('x86_64');

sub capture_stdout {
  my ($fn) = @_;
  local *STDOUT;
  open(STDOUT, '>', \my $cap) || die;
  $fn->();
  return $cap;
}

my @sources = map { "https://example.org/$_" } (
    "phalanx-XXV-source.tgz",
    "stockfish-10-src.zip",
    "gnuchess-6.2.5.tar.gz",
    "gnome-chess-3.36.1.tar.xz",
);

subtest parse => sub {
    plan skip_all => 'no YAML parser' unless Build::Flatpak::_have_yaml_parser();
    my $expected = {
        name => 'org.gnome.Chess',
        version => '3.36.2',
        sources => [
            @sources,
        ],
        deps => [
            'org.gnome.Sdk-v3.36',
            'org.gnome.Platform-v3.36',
        ],
    };
    my $yaml = do { local $/; <DATA> };
    my $data = Build::Flatpak::parse($conf, \$yaml);
    is_deeply $data, $expected, 'parse() YAML flatpak content';

    $data = Build::Flatpak::parse($conf, "$path/flatpak.yaml");
    is_deeply $data, $expected, 'parse() YAML flatpak file';

    $data = Build::Flatpak::parse($conf, "$path/flatpak.json");
    is_deeply $data, $expected, 'parse() JSON flatpak file';
};

subtest show => sub {
    plan skip_all => 'no YAML parser' unless Build::Flatpak::_have_yaml_parser();
    local @ARGV = ("$path/flatpak.yaml", 'name');
    my $data = capture_stdout(sub { Build::Flatpak::show() });
    is $data, "org.gnome.Chess\n", 'Build::Flatpak::show name';

    @ARGV = ("$path/flatpak.yaml", 'sources');
    $data = capture_stdout(sub { Build::Flatpak::show() });
    my $exp_sources = join '', map { "$_\n" } @sources;
    is $data, $exp_sources, 'Build::Flatpak::show sources';
};

subtest rewrite => sub {
    plan skip_all => 'no YAML parser' unless Build::Flatpak::_have_yaml_parser();
    local @ARGV = ("$path/flatpak.yaml");
    my $yaml = capture_stdout(sub { Build::Flatpak::rewrite() });
    my $ok = is $yaml, $rewritten_manifest, 'Build::Flatpak::show rewrite';
    unless ($ok) {
        open my $fh, '>', "/tmp/flatpak.t.compare.yaml" or die $!;
        print $fh $yaml;
        close $fh;
        my $diff = qx{diff $Bin/data/flatpak-rewritten.yaml /tmp/flatpak.t.compare.yaml};
        diag "Diff:\n$diff";
    }

};

done_testing;

__DATA__
#!BuildVersion: 3.36.2
{
    "app-id": "org.gnome.Chess",
    "runtime": "org.gnome.Platform",
    "runtime-version": "3.36",
    "sdk": "org.gnome.Sdk",
    "command": "gnome-chess",
    "finish-args": [
        "--share=ipc", "--socket=fallback-x11",
        "--socket=wayland",
        "--metadata=X-DConf=migrate-path=/org/gnome/Chess/"
    ],
    "cleanup": ["/share/gnuchess", "/share/info", "/share/man", "/include"],
    "modules": [
        {
            "name": "phalanx",
            "buildsystem": "simple",
            "build-commands": [
                "make",
                "install -D phalanx /app/bin/phalanx",
                "install -D pbook.phalanx /app/share/phalanx/pbook.phalanx",
                "install -D sbook.phalanx /app/share/phalanx/sbook.phalanx",
                "install -D eco.phalanx /app/share/phalanx/eco.phalanx"
            ],
            "sources": [
                {
                    "type": "archive",
                    "url": "https://example.org/phalanx-XXV-source.tgz",
                    "sha256": "b3874d5dcd22c64626b2c955b18b27bcba3aa727855361a91eab57a6324b22dd"
                },
                {
                    "type": "patch",
                    "path": "phalanx-books-path.patch"
                }
            ]
        },
        {
            "name": "stockfish",
            "buildsystem": "simple",
            "build-options" : {
                "arch": {
                    "x86_64": {
                        "env": {
                            "ARCH": "x86-64"
                        }
                    },
                    "arm": {
                        "env": {
                            "ARCH": "armv7"
                        }
                    },
                    "aarch64": {
                        "env": {
                            "ARCH": "armv7"
                        }
                    }
                }
            },
            "build-commands": [
                "make build",
                "install -D stockfish /app/bin/stockfish"
            ],
            "sources": [
                {
                    "type": "archive",
                    "url": "https://example.org/stockfish-10-src.zip",
                    "sha256": "29bd01e7407098aa9e851b82f6ea4bf2b46d26e9075a48a269cb1e40c582a073"
                }
            ]
        },
        {
            "name": "gnuchess",
            "sources": [
                {
                    "type": "archive",
                    "url": "https://example.org/gnuchess-6.2.5.tar.gz",
                    "sha256": "9a99e963355706cab32099d140b698eda9de164ebce40a5420b1b9772dd04802"
                }
            ]
        },
        {
            "name": "gnome-chess",
            "buildsystem": "meson",
            "sources": [
                {
                    "type": "archive",
                    "url": "https://example.org/gnome-chess-3.36.1.tar.xz",
                    "sha256": "b195c9f17a59d7fcc892ff55e6a6ebdd16e7329157bf37e3c2fe593b349aab98"
                }
            ]
        }
    ]
}
