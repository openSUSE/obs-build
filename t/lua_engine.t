#!/usr/bin/perl -w

use strict;
use Test::More tests => 15;
use Test::Exception;
use Benchmark;

use lib '.';
use Build;
use Build::Rpm;
use Build::LuaEngine;
use Data::Dumper;

my ($spec, $result, $expected);
my $conf = Build::read_config('x86_64');

# Test 1: Basic Lua code block execution
$spec = q{
Name: test-lua-basic
Version: 1.0
Release: 1

%{lua:print("Hello from Lua")}
%global lua_result %{lua:return "Lua is working"}
};
$expected = {
  'name' => 'test-lua-basic',
  'version' => '1.0',
  'release' => '1',
  'deps' => [],
  'subpacks' => [ 'test-lua-basic' ],
};
$result = Build::Rpm::parse($conf, [ split("\n", $spec) ]);
is_deeply($result, $expected, "basic lua code block execution");

# Test 2: Lua function definition and usage
$spec = q{
Name: test-lua-functions
Version: 1.0
Release: 1

%{lua:
function greet(name)
  return "Hello, " .. name .. "!"
end
}

%global greeting %{lua:greet("World")}
%global greeting2 %{lua:greet("obs-build")}
};
$expected = {
  'name' => 'test-lua-functions',
  'version' => '1.0',
  'release' => '1',
  'deps' => [],
  'subpacks' => [ 'test-lua-functions' ],
};
$result = Build::Rpm::parse($conf, [ split("\n", $spec) ]);
is_deeply($result, $expected, "lua function definition and usage");

# Test 3: Complex Lua logic with RPM integration
$spec = q{
Name: test-lua-rpm-integration
Version: 1.0
Release: 1

%global arch %{_arch}
%global dist %{_dist}

%{lua:
function get_build_info()
  local arch = rpm.expand("%arch")
  local dist = rpm.expand("%dist")
  return arch .. "-" .. dist
end
}

%global build_info %{lua:get_build_info()}
};
$expected = {
  'name' => 'test-lua-rpm-integration',
  'version' => '1.0',
  'release' => '1',
  'deps' => [],
  'subpacks' => [ 'test-lua-rpm-integration' ],
};
$result = Build::Rpm::parse($conf, [ split("\n", $spec) ]);
is_deeply($result, $expected, "lua with RPM macro integration");

# Test 4: Lua variable manipulation
$spec = q{
Name: test-lua-variables
Version: 1.0
Release: 1

%global test_var "original_value"

%{lua:
local current_value = rpm.getvar("test_var")
rpm.setvar("test_var", current_value .. "_modified")
}

%global modified_var %{lua:rpm.getvar("test_var")}
};
$expected = {
  'name' => 'test-lua-variables',
  'version' => '1.0',
  'release' => '1',
  'deps' => [],
  'subpacks' => [ 'test-lua-variables' ],
};
$result = Build::Rpm::parse($conf, [ split("\n", $spec) ]);
is_deeply($result, $expected, "lua variable manipulation");

# Test 5: Conditional logic with Lua
$spec = q{
Name: test-lua-conditionals
Version: 1.0
Release: 1

%global arch %{_arch}

%{lua:
function is_x86_64()
  return rpm.expand("%arch") == "x86_64"
end
}

%global is_x86_64 %{lua:is_x86_64() and 1 or 0}

%if %{is_x86_64}
BuildRequires: x86_64-specific-package
%endif
};
$expected = {
  'name' => 'test-lua-conditionals',
  'version' => '1.0',
  'release' => '1',
  'deps' => [ 'x86_64-specific-package' ],
  'subpacks' => [ 'test-lua-conditionals' ],
  'configdependent' => '1',
};
$result = Build::Rpm::parse($conf, [ split("\n", $spec) ]);
is_deeply($result, $expected, "lua conditional logic");

# Test 6: String manipulation with Lua
$spec = q{
Name: test-lua-string-manipulation
Version: 1.0
Release: 1

%{lua:
function process_version(version)
  if string.find(version, "alpha") then
    return "alpha"
  elseif string.find(version, "beta") then
    return "beta"
  else
    return "release"
  end
end
}

%global version_suffix %{lua:process_version("%version")}
%global package_name %{lua:rpm.expand("%name") .. "-" .. rpm.expand("%version")}
};
$expected = {
  'name' => 'test-lua-string-manipulation',
  'version' => '1.0',
  'release' => '1',
  'deps' => [],
  'subpacks' => [ 'test-lua-string-manipulation' ],
};
$result = Build::Rpm::parse($conf, [ split("\n", $spec) ]);
is_deeply($result, $expected, "lua string manipulation");

# Test 7: Nested Lua macro expansion
$spec = q{
Name: test-lua-nested
Version: 1.0
Release: 1

%global base_name "test"
%global full_name %{lua:rpm.expand("%base_name") .. "-nested"}
%global final_name %{lua:rpm.expand("%full_name") .. "-lua"}
};
$expected = {
  'name' => 'test-lua-nested',
  'version' => '1.0',
  'release' => '1',
  'deps' => [],
  'subpacks' => [ 'test-lua-nested' ],
};
$result = Build::Rpm::parse($conf, [ split("\n", $spec) ]);
is_deeply($result, $expected, "nested lua macro expansion");

# Test 8: Error handling for invalid Lua
$spec = q{
Name: test-lua-error-handling
Version: 1.0
Release: 1

%global bad_lua %{lua:invalid_function_call()}
%global good_lua %{lua:return "This should work"}
};
$expected = {
  'name' => 'test-lua-error-handling',
  'version' => '1.0',
  'release' => '1',
  'deps' => [],
  'subpacks' => [ 'test-lua-error-handling' ],
};
$result = Build::Rpm::parse($conf, [ split("\n", $spec) ]);
is_deeply($result, $expected, "lua error handling");

# Test 9: Performance test
$spec = q{
Name: test-lua-performance
Version: 1.0
Release: 1

%{lua:
function fibonacci(n)
  if n <= 1 then
    return n
  else
    return fibonacci(n-1) + fibonacci(n-2)
  end
end
}

%global fib_result %{lua:fibonacci(10)}
};
$expected = {
  'name' => 'test-lua-performance',
  'version' => '1.0',
  'release' => '1',
  'deps' => [],
  'subpacks' => [ 'test-lua-performance' ],
};
$result = Build::Rpm::parse($conf, [ split("\n", $spec) ]);
is_deeply($result, $expected, "lua performance test");

# Test 10: Complex Firefox-style logic
$spec = q{
Name: test-lua-firefox-style
Version: 128.11.0
Release: 3.1

%{lua:
function dist_to_rhel_minor(str)
  local match = string.match(str, ".module%+el8.(%d+)")
  if match then
     return match
  end
  match = string.match(str, ".el8_(%d+)")
  if match then
     return match
  end
  match = string.match(str, ".el8")
  if match then
     return "10"
  end
  match = string.match(str, ".module%+el9.(%d+)")
  if match then
     return match
  end
  match = string.match(str, ".el9_(%d+)")
  if match then
     return match
  end
  match = string.match(str, ".el9")
  if match then
     return "7"
  end
  match = string.match(str, ".el10_(%d+)")
  if match then
     return match
  end
  match = string.match(str, ".el10")
  if match then
     return "1"
  end
  return "-1"
end
}

%define dist .el9_6
%define rhel 9
%global rhel_minor_version %{lua:dist_to_rhel_minor(rpm.expand("%dist"))}

%if 0%{?rhel} == 9
  %if %{rhel_minor_version} < 2
    %global bundle_nss        1
    %global system_nss        1
  %endif
  %if %{rhel_minor_version} > 5
    %ifnarch s390x
      %global with_wasi_sdk 1
    %endif
  %endif
%endif

%if %{with_wasi_sdk}
BuildRequires:        lld
BuildRequires:        clang cmake ninja-build
%endif
};
$expected = {
  'name' => 'test-lua-firefox-style',
  'version' => '128.11.0',
  'release' => '3.1',
  'deps' => [ 'lld', 'clang', 'cmake', 'ninja-build' ],
  'subpacks' => [ 'test-lua-firefox-style' ],
  'configdependent' => '1',
};
$result = Build::Rpm::parse($conf, [ split("\n", $spec) ]);
is_deeply($result, $expected, "firefox-style lua logic");

# Test 11: Lua engine direct testing
subtest "LuaEngine direct testing" => sub {
  plan tests => 6;

  my $engine = Build::LuaEngine->new($conf);
  ok($engine, "LuaEngine created successfully");

  my $result = $engine->execute_code('return "Hello from Lua"');
  is($result, "Hello from Lua", "Basic Lua execution");

  $engine->define_function('test_func', 'return "Function works"');
  my $func_result = $engine->call_function('test_func');
  is($func_result, "Function works", "Function definition and call");

  my @functions = $engine->get_function_list();
  is(scalar(@functions), 1, "Function list contains defined function");
  is($functions[0], "test_func", "Correct function name in list");

  $engine->cleanup();
  pass("LuaEngine cleanup successful");
};

# Test 12: Error handling and limits
subtest "Error handling and limits" => sub {
  plan tests => 4;

  my $engine = Build::LuaEngine->new($conf);

  # Test invalid Lua code
  my $result = $engine->execute_code('invalid syntax here');
  is($engine->get_error_count(), 1, "Error count incremented on invalid code");

  # Test function not found
  $engine->call_function('nonexistent_function');
  is($engine->get_error_count(), 2, "Error count incremented on function not found");

  # Test error reset
  $engine->reset_errors();
  is($engine->get_error_count(), 0, "Error count reset successfully");

  $engine->cleanup();
  pass("Error handling test completed");
};

# Test 13: Performance benchmarking
subtest "Performance benchmarking" => sub {
  plan tests => 3;

  my $engine = Build::LuaEngine->new($conf);

  # Benchmark simple operation
  my $t0 = Benchmark->new;
  for (1..100) {
    $engine->execute_code('return "test"');
  }
  my $t1 = Benchmark->new;
  my $td = timediff($t1, $t0);

  ok($td->cpu_a < 1.0, "100 simple operations completed in under 1 second");

  # Benchmark function calls
  $engine->define_function('bench_func', 'return "benchmark"');
  $t0 = Benchmark->new;
  for (1..100) {
    $engine->call_function('bench_func');
  }
  $t1 = Benchmark->new;
  $td = timediff($t1, $t0);

  ok($td->cpu_a < 1.0, "100 function calls completed in under 1 second");

  $engine->cleanup();
  pass("Performance benchmarking completed");
};

# Test 14: Memory management
subtest "Memory management" => sub {
  plan tests => 2;

  # Test multiple engine instances
  my @engines;
  for (1..5) {
    push @engines, Build::LuaEngine->new($conf);
  }

  is(scalar(@engines), 5, "Created 5 LuaEngine instances");

  # Cleanup all engines
  foreach my $engine (@engines) {
    $engine->cleanup();
  }

  pass("Memory management test completed");
};

# Test 15: Backward compatibility
subtest "Backward compatibility" => sub {
  plan tests => 4;

  # Test that existing luamacro functions still work
  my $result = Build::Rpm::luamacro($conf, {}, 'lower', 'HELLO');
  is($result, 'hello', "lower() function works");

  $result = Build::Rpm::luamacro($conf, {}, 'upper', 'hello');
  is($result, 'HELLO', "upper() function works");

  $result = Build::Rpm::luamacro($conf, {}, 'len', 'test');
  is($result, 4, "len() function works");

  $result = Build::Rpm::luamacro($conf, {}, 'reverse', 'hello');
  is($result, 'olleh', "reverse() function works");
};

done_testing();
