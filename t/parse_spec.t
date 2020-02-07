#!/usr/bin/perl -w

use strict;
use Test::More tests => 9;

use Build;
use Build::Rpm;
use Data::Dumper;

my ($spec, $spec2);
my $result;
my $expected;

my $conf = Build::read_config('x86_64');


$spec = q{
Name: foo
Version: 1.0
Release: 1
ExclusiveArch: x86_64
ExcludeArch: i586
};
$expected = {
  'name' => 'foo',
  'version' => '1.0',
  'release' => '1',
  'exclarch' => [ 'x86_64' ],
  'badarch' => [ 'i586' ],
  'deps' => [],
  'subpacks' => [ 'foo' ],
};
$result = Build::Rpm::parse($conf, [ split("\n", $spec) ]);
is_deeply($result, $expected, "preamble");


$spec = q{
BuildRequires: foo
BuildRequires: bar > 1,baz
};
$expected = {
  'deps' => [ 'foo', 'bar > 1', 'baz' ],
  'subpacks' => [],
};
$result = Build::Rpm::parse($conf, [ split("\n", $spec) ]);
is_deeply($result, $expected, "simple build requires");


$spec = q{
BuildRequires: foo (bar > 1 || (baz)) xxx
};
$expected = {
  'deps' => [ 'foo', '(bar > 1 || (baz))', 'xxx' ],
  'subpacks' => [],
};
$result = Build::Rpm::parse($conf, [ split("\n", $spec) ]);
is_deeply($result, $expected, "rich build requires");


$spec = q{
Requires(pre): foo
PreReq: bar
Requires(post): baz
Requires(xxx): xxx
};
$expected = {
  'deps' => [],
  'prereqs' => [ 'foo', 'bar', 'baz' ],
  'subpacks' => [],
};
$result = Build::Rpm::parse($conf, [ split("\n", $spec) ]);
is_deeply($result, $expected, "pre requires");


$spec = q{
%if 1
BuildRequires: foo1
%endif

%if 0
BuildRequires: foo2
%endif

%if 1
BuildRequires: foo3
%else
BuildRequires: foo4
%endif

%if 0
BuildRequires: foo5
%else
BuildRequires: foo6
%endif

BuildRequires: foo7

%if ""
BuildRequires: foo8
%endif

%if "0"
BuildRequires: foo9
%endif
};
$expected = {
  'deps' => [ 'foo1', 'foo3', 'foo6', 'foo7', 'foo9' ],
  'subpacks' => [],
  'configdependent' => 1,
};
$result = Build::Rpm::parse($conf, [ split("\n", $spec) ]);
is_deeply($result, $expected, "if statements");


$spec = q{
%if 1
%if 1
BuildRequires: foo1
%endif

%if 0
BuildRequires: foo2
%endif
%endif

%if 0
%if 1
BuildRequires: foo3
%endif

%if 0
BuildRequires: foo4
%endif
%endif

%if 1
%if 1
BuildRequires: foo5
%endif

%if 0
BuildRequires: foo6
%endif

%else

%if 1
BuildRequires: foo7
%endif

%if 0
BuildRequires: foo8
%endif
%endif

%if 0
%if 1
BuildRequires: foo9
%endif

%if 0
BuildRequires: foo10
%endif

%else

%if 1
BuildRequires: foo11
%endif

%if 0
BuildRequires: foo12
%endif
%endif
};
$expected = {
  'deps' => [ 'foo1', 'foo5', 'foo11' ],
  'subpacks' => [],
  'configdependent' => 1,
};
$result = Build::Rpm::parse($conf, [ split("\n", $spec) ]);
is_deeply($result, $expected, "nested if statements");


$spec = q{
%ifarch i586
BuildRequires: foo1
%endif

%ifarch x86_64
BuildRequires: foo2
%endif

%ifarch i586 x86_64
BuildRequires: foo3
%endif

%ifnarch i586
BuildRequires: foo1
%endif

%ifnarch x86_64
BuildRequires: foo2
%endif

%ifnarch i586 x86_64
BuildRequires: foo3
%endif
};
$expected = {
  'deps' => [ 'foo2', 'foo3', 'foo1' ],
  'subpacks' => [],
  'configdependent' => 1,
};
$result = Build::Rpm::parse($conf, [ split("\n", $spec) ]);
is_deeply($result, $expected, "ifarch statements");

$spec = q{
BuildRequires: foo
%include spec2
};
$spec2 = q{
BuildRequires: bar
};
$expected = {
  'deps' => [ 'foo', 'bar' ],
  'subpacks' => [],
};
$Build::Rpm::includecallback = sub { $_[0] eq 'spec2' ? $spec2 : undef };
$result = Build::Rpm::parse($conf, [ split("\n", $spec) ]);
is_deeply($result, $expected, "include statement");

$spec = q{
%if 0
BuildRequires: foo1_1
%elif 0
BuildRequires: foo2_1
%if 1
%elif 1
%else
%endif
%elif 0
BuildRequires: foo3_1
%else
BuildRequires: foo4_1
%endif

%if 1
BuildRequires: foo1_2
%if 1
%elif 1
%else
%endif
%elif 0
BuildRequires: foo2_2
%elif 0
BuildRequires: foo3_2
%else
BuildRequires: foo4_2
%endif

%if 0
BuildRequires: foo1_3
%elif 1
BuildRequires: foo2_3
%elif 0
BuildRequires: foo3_3
%if 1
%elif 1
%else
%endif
%else
BuildRequires: foo4_3
%endif

%if 1
BuildRequires: foo1_4
%if 1
%elif 1
%else
%endif
%elif 1
BuildRequires: foo2_4
%elif 0
BuildRequires: foo3_4
%else
BuildRequires: foo4_4
%endif

%if 0
BuildRequires: foo1_5
%elif 0
%if 1
%elif 1
%else
%endif
BuildRequires: foo2_5
%elif 1
BuildRequires: foo3_5
%else
BuildRequires: foo4_5
%endif

%if 1
BuildRequires: foo1_6
%elif 0
BuildRequires: foo2_6
%elif 1
BuildRequires: foo3_6
%else
BuildRequires: foo4_6
%endif

%if 0
BuildRequires: foo1_7
%if 1
%elif 1
%else
%endif
%elif 1
BuildRequires: foo2_7
%elif 1
BuildRequires: foo3_7
%if 1
%elif 1
%else
%endif
%else
BuildRequires: foo4_7
%endif

%if 1
BuildRequires: foo1_8
%elif 1
BuildRequires: foo2_8
%elif 1
BuildRequires: foo3_8
%else
BuildRequires: foo4_8
%endif
};
$expected = {
  'deps' => [ 'foo4_1', 'foo1_2', 'foo2_3', 'foo1_4', 'foo3_5', 'foo1_6', 'foo2_7', 'foo1_8' ],
  'subpacks' => [],
  'configdependent' => 1,
};
$result = Build::Rpm::parse($conf, [ split("\n", $spec) ]);
is_deeply($result, $expected, "elif statements");

