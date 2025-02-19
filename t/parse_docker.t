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

RUN zypper install wget curl

RUN curl -sL --output /usr/bin/example-curl --retry 3 -u "foo:bar" https://localhost:8080/example-curl
RUN wget -O /usr/bin/example-wget -t 3 --user foo --password bar https://localhost:8080/example-wget

FROM opensuse/leap:15.2
};

$expected = {
  'name' => 'docker',
  'deps' => [
    'container:opensuse/tumbleweed:latest',
    'wget',
    'curl',
    'container:opensuse/leap:15.2',
  ],
  'path' => [],
  'imagerepos' => [],
  'basecontainer' => 'opensuse/leap:15.2',
  'remoteassets' => [
    {
      'type' => 'webcache',
      'url' => 'https://localhost:8080/example-curl'
    },
{
      'type' => 'webcache',
      'url' => 'https://localhost:8080/example-wget'
    }
  ],
};

$result = Build::Docker::parse($conf, \$dockerfile);
is_deeply($result, $expected);
