#!/usr/bin/perl -w

use strict;
use Test::More tests => 1;

use Build;
use Build::Docker;

my ($dockerfile);
my $result;
my $expected;

my $conf = Build::read_config('x86_64');

$dockerfile = q{
FROM opensuse/tumbleweed AS tw

# debug
RUN cat /etc/os-release

FROM opensuse/leap:15.2
};

$expected = {
  'name' => 'docker',
  'deps' => ['container:opensuse/tumbleweed:latest', 'container:opensuse/leap:15.2'],
  'path' => [],
  'imagerepos' => [],
  'basecontainer' => 'container:opensuse/leap:15.2',
};

$result = Build::Docker::parse($conf, \$dockerfile);
is_deeply($result, $expected);
