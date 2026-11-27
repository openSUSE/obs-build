#!/usr/bin/perl

use strict;
use warnings;
use Test::More;
use PBuild::Recipe;

sub find_recipe {
    my ($type, @filenames) = @_;

    my %files = map { $_ => 1 } @filenames;

    return PBuild::Recipe::find_recipe(
        {
            pkg   => 'demo',
            files => \%files,
        },
        $type
    );
}

is(
    find_recipe('docker', 'Dockerfile'),
    'Dockerfile',
    'normal Dockerfile is detected'
);

is(
    find_recipe('docker', 'Dockerfile.demo'),
    'Dockerfile.demo',
    'package-specific Dockerfile is detected'
);

is(
    find_recipe('docker', 'Dockerfile.dapper'),
    'Dockerfile.dapper',
    'Dapper recipe is detected with Type docker'
);

is(
    find_recipe('docker', 'Dockerfile', 'Dockerfile.dapper'),
    'Dockerfile',
    'normal Dockerfile keeps priority'
);

is(
    find_recipe('docker', 'Dockerfile.demo', 'Dockerfile.dapper'),
    'Dockerfile.demo',
    'package-specific Dockerfile keeps priority'
);

is(
    Build::recipe2buildtype('Dockerfile.dapper'),
    'docker',
    'Dapper recipe uses the Docker build type'
);

is(
    find_recipe('spec', 'Dockerfile.dapper'),
    undef,
    'Dapper recipe is not selected for RPM spec builds'
);

is(
    find_recipe('docker', 'demo.docker', 'Dockerfile.dapper'),
    'demo.docker',
    'existing .docker recipe retains priority'
);

done_testing();
