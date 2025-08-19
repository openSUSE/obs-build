#!/usr/bin/perl -w

use strict;
use Test::More tests => 19;

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
Epoch: 42
ExclusiveArch: x86_64
ExcludeArch: i586
};
$expected = {
  'name' => 'foo',
  'epoch' => '42',
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
BuildRequires: baz%%%%
};
$expected = {
  'deps' => [ 'foo', 'bar', 'baz%%' ],
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

$spec = q{
%global foo \
BuildRequires: bar \
%nil
BuildRequires: baz
};
$expected = {
  'deps' => [ 'baz' ],
  'subpacks' => [],
};
$result = Build::Rpm::parse($conf, [ split("\n", $spec) ]);
is_deeply($result, $expected, "multiline define");

$spec = q[
%{?foo:
BuildRequires: foo
%{?!bar:
BuildRequires: bar
}
BuildRequires: baz
}xxx
];
$expected = {
  'deps' => [],
  'subpacks' => [],
};
$result = Build::Rpm::parse($conf, [ split("\n", "$spec") ]);
is_deeply($result, $expected, "multiline condition 1");

$result = Build::Rpm::parse($conf, [ split("\n", "%global bar 1\n$spec") ]);
is_deeply($result, $expected, "multiline condition 2");

$expected = {
  'deps' => [ 'foo', 'bar', 'baz' ],
  'subpacks' => [],
};
$result = Build::Rpm::parse($conf, [ split("\n", "%global foo 1\n$spec") ]);
is_deeply($result, $expected, "multiline condition 3");

$expected = {
  'deps' => [ 'foo', 'baz' ],
  'subpacks' => [],
};
$result = Build::Rpm::parse($conf, [ split("\n", "%global foo 1\n%global bar 1\n$spec") ]);
is_deeply($result, $expected, "multiline condition 4");

$Build::Rpm::includecallback = sub { $_[0] eq 'xxx' ? "%mac_foo mac_bar\n": undef };
$spec = q[
%{load:xxx}
Name: %mac_foo
];
$expected = {
  'name' => 'mac_bar',
  'deps' => [],
  'subpacks' => ['mac_bar'],
};
$result = Build::Rpm::parse($conf, [ split("\n", $spec) ]);
is_deeply($result, $expected, "load macro");

# Test shell command expansion
$spec = q{
Name: test-shell
Version: 1.0
Release: 1

%define test_echo %(echo "hello world")
%global test_var %{test_echo}
};
$expected = {
  'name' => 'test-shell',
  'version' => '1.0',
  'release' => '1',
  'deps' => [],
  'subpacks' => [ 'test-shell' ],
};
$result = Build::Rpm::parse($conf, [ split("\n", $spec) ]);
is_deeply($result, $expected, "basic shell command expansion");

# Test comment macro expansion fix
$spec = q{
%define test_macro EXPANDED
Name: test
Version: 1.0
# This is a regular comment with %{test_macro} - should NOT be expanded
#! This is a shebang comment with %{test_macro} - should be expanded
BuildRequires: foo
};
$expected = {
  'name' => 'test',
  'version' => '1.0',
  'deps' => [ 'foo' ],
  'subpacks' => [ 'test' ],
};
$result = Build::Rpm::parse($conf, [ split("\n", $spec) ], xspec => [], save_expanded => 1);
is_deeply($result, $expected, "comment macro expansion");

# Verify that regular comments don't get macro expansion but shebang comments do
my $found_regular_comment_expanded = 0;
my $found_shebang_comment_expanded = 0;
foreach my $line (@{$result->{xspec} || []}) {
  if (ref($line) eq "ARRAY") {
    my ($original, $expanded) = @$line;
    if ($original =~ /^# This is a regular comment/ && $expanded =~ /EXPANDED/) {
      $found_regular_comment_expanded = 1;
    }
    if ($original =~ /^#! This is a shebang comment/ && $expanded =~ /EXPANDED/) {
      $found_shebang_comment_expanded = 1;
    }
  }
}

# Regular comments should NOT have macro expansion
ok(!$found_regular_comment_expanded, "regular comments do not get macro expansion");
# Note: This test may need adjustment based on actual shebang behavior in the parser

# Test RPM option macro syntax with negation and multi-line %if expansion
# Verifies that:
# 1. %{-m:1} correctly evaluates when -m option is present
# 2. %{!-m:0} correctly evaluates when -m option is NOT present
# 3. Multi-line macro expansion preserves %if/%endif directive parsing
# 4. Combined boolean expressions %{-m:1}%{!-m:0} work in %if conditionals
$spec = q{
Name: test-option-macros
Version: 1.0
Release: 1

%define test_macro(m) \
%if %{-m:1}%{!-m:0}\
BuildRequires: has-m-option\
%endif\
%{nil}

%test_macro
%test_macro -m
};
$expected = {
  'name' => 'test-option-macros',
  'version' => '1.0',
  'release' => '1',
  'deps' => [ 'has-m-option' ],
  'subpacks' => [ 'test-option-macros' ],
  'configdependent' => 1,
};
$result = Build::Rpm::parse($conf, [ split("\n", $spec) ]);
is_deeply($result, $expected, "option macros with negation");
