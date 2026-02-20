################################################################
#
# Copyright (c) 2025 Mohamed Rekiba <muhammad.shaban.dev@gmail.com>
# Copyright (c) 2024 SUSE Linux Products GmbH
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

package Build::LuaEngine;

use strict;
use warnings;
use Lua::API;

=head1 NAME

Build::LuaEngine - Lua scripting engine for RPM spec processing

=head1 SYNOPSIS

  use Build::LuaEngine;

  my $engine = Build::LuaEngine->new($config);
  my $result = $engine->execute_code('return "Hello from Lua"');
  $engine->define_function('test_func', 'return "Function works"');
  my $func_result = $engine->call_function('test_func');
  $engine->cleanup();

=head1 DESCRIPTION

This module provides a comprehensive Lua scripting engine for processing
RPM spec files within the OBS build system. It integrates with perl(Lua::API)
to provide full Lua functionality including function persistence, RPM macro
integration, and proper error handling.

=cut

=head1 CONSTRUCTOR

=head2 new($config)

Creates a new LuaEngine instance with the given build configuration.

=cut

sub new {
    my ($class, $config) = @_;

    # Create Lua state
    my $lua = Lua::API::State->new();
    unless ($lua) {
        die "Failed to create Lua state";
    }

    # Open standard Lua libraries
    $lua->openlibs();

    my $self = {
        lua => $lua,
        config => $config,
        functions => {},
        error_count => 0,
        rpm_context => undef,
    };

    bless $self, $class;

    # Set up RPM integration functions
    $self->_setup_rpm_functions();

    # Set up security sandbox
    $self->_setup_sandbox();

    return $self;
}

=head1 METHODS

=head2 execute_code($lua_code)

Executes the given Lua code and returns the result as a string.
If the code returns multiple values, only the first is returned.
Returns empty string on error.

=cut

sub execute_code {
    my ($self, $code) = @_;

    return '' unless defined $code && $code ne '';

    # Wrap code to capture return value
    my $wrapped_code = $self->_wrap_code_for_execution($code);

    my $result = '';
    eval {
        # Use dostring for simple execution
        my $status = $self->{lua}->dostring($wrapped_code);
        if ($status != 0) {
            my $error = $self->{lua}->tostring(-1) || "Unknown Lua error";
            $self->_handle_lua_error("Lua execution error: $error");
            $self->{lua}->pop(1);
            return '';
        }

        # Get result from stack
        if ($self->{lua}->gettop() > 0) {
            if ($self->{lua}->isstring(-1)) {
                $result = $self->{lua}->tostring(-1) || '';
            } elsif ($self->{lua}->isnumber(-1)) {
                $result = '' . ($self->{lua}->tonumber(-1) || 0);  # Convert to string
            } elsif ($self->{lua}->isboolean(-1)) {
                $result = $self->{lua}->toboolean(-1) ? '1' : '0';  # Convert to string
            }
            $self->{lua}->pop(1);
        }
    };

    if ($@) {
        $self->_handle_lua_error("Perl error in Lua execution: $@");
        return '';
    }

    return $result;
}

=head2 define_function($name, $code)

Defines a Lua function with the given name and code.
The function will be available for subsequent calls.

=cut

sub define_function {
    my ($self, $name, $code) = @_;

    return 0 unless defined $name && $name ne '' && defined $code;

    # Wrap function definition
    my $func_def = "function $name() $code end";

    my $result = $self->execute_code($func_def);
    if ($self->{error_count} == 0 || $result ne '') {
        $self->{functions}->{$name} = $code;
        return 1;
    }

    return 0;
}

=head2 call_function($name, @args)

Calls a previously defined Lua function with the given arguments.
Returns the function result as a string.

=cut

sub call_function {
    my ($self, $name, @args) = @_;

    return '' unless defined $name && $name ne '';

    unless (exists $self->{functions}->{$name}) {
        $self->_handle_lua_error("Function '$name' not found");
        return '';
    }

    # Prepare function call
    my $call_code = $name . '()';
    if (@args) {
        my $arg_list = join(', ', map { $self->_quote_lua_arg($_) } @args);
        $call_code = "$name($arg_list)";
    }

    return $self->execute_code("return $call_code");
}

=head2 get_function_list()

Returns a list of defined function names.

=cut

sub get_function_list {
    my ($self) = @_;
    return sort keys %{$self->{functions}};
}

=head2 get_error_count()

Returns the number of errors encountered since creation or last reset.

=cut

sub get_error_count {
    my ($self) = @_;
    return $self->{error_count};
}

=head2 reset_errors()

Resets the error counter to zero.

=cut

sub reset_errors {
    my ($self) = @_;
    $self->{error_count} = 0;
}

=head2 set_rpm_context(\%context)

Sets the RPM context for macro expansion and variable access.
The context should contain at least a 'macros' hash reference.

=cut

sub set_rpm_context {
    my ($self, $context) = @_;
    $self->{rpm_context} = $context;
}

=head2 cleanup()

Cleans up Lua state and resources. Should be called when done with the engine.

=cut

sub cleanup {
    my ($self) = @_;

    if ($self->{lua}) {
        $self->{lua}->close();
        $self->{lua} = undef;
    }

    $self->{functions} = {};
    $self->{error_count} = 0;
    $self->{rpm_context} = undef;
}

# DESTROY is called automatically when object goes out of scope
sub DESTROY {
    my ($self) = @_;
    $self->cleanup();
}

=head1 INTERNAL METHODS

=cut

# Wrap code for execution, handling print() statements and return values
sub _wrap_code_for_execution {
    my ($self, $code) = @_;

    # Handle simple expressions that should return a value
    if ($code !~ /\breturn\b/ && $code !~ /\bfunction\b/ && $code !~ /\bprint\b/ &&
        $code !~ /\bif\b/ && $code !~ /\bfor\b/ && $code !~ /\bwhile\b/) {
        # Simple expression, wrap with return
        $code = "return ($code)";
    }

    # Handle print() statements - capture output
    if ($code =~ /\bprint\s*\(/) {
        # Replace print with our capture function and wrap with return
        $code =~ s/\bprint\s*\(/__print_capture(/g;
        # If code only contains print statements, wrap the result in return
        if ($code =~ /^__print_capture\(.*\)$/) {
            $code = "return $code";
        }
    }

    return $code;
}

# Handle Lua errors
sub _handle_lua_error {
    my ($self, $error) = @_;

    $self->{error_count}++;

    # In a real implementation, we might want to log this
    # For now, we'll just count errors
    if ($self->{config} && ref($self->{config}) eq 'HASH') {
        # Could integrate with Build::Rpm::do_warn here
        warn "Lua error: $error" if $ENV{BUILD_DEBUG};
    }
}

# Quote Lua argument for function calls
sub _quote_lua_arg {
    my ($self, $arg) = @_;

    return 'nil' unless defined $arg;

    # Numbers don't need quoting
    if ($arg =~ /^-?\d+\.?\d*$/) {
        return $arg;
    }

    # Quote strings and escape quotes
    $arg =~ s/\\/\\\\/g;
    $arg =~ s/"/\\"/g;
    return "\"$arg\"";
}

# Set up RPM integration functions
sub _setup_rpm_functions {
    my ($self) = @_;

    # Create rpm table
    $self->{lua}->dostring('rpm = {}');

    # rpm.expand function
    $self->{lua}->register('__rpm_expand', sub {
        my ($lua) = @_;
        my $macro = $lua->tostring(1) || '';
        my $result = $self->_rpm_expand($macro);
        $lua->pushstring($result);
        return 1;
    });

    # rpm.getvar function
    $self->{lua}->register('__rpm_getvar', sub {
        my ($lua) = @_;
        my $name = $lua->tostring(1) || '';
        my $result = $self->_rpm_getvar($name);
        $lua->pushstring($result);
        return 1;
    });

    # rpm.setvar function
    $self->{lua}->register('__rpm_setvar', sub {
        my ($lua) = @_;
        my $name = $lua->tostring(1) || '';
        my $value = $lua->tostring(2) || '';
        $self->_rpm_setvar($name, $value);
        return 0;
    });

    # Print capture function
    $self->{lua}->register('__print_capture', sub {
        my ($lua) = @_;
        my @args;
        my $top = $lua->gettop();
        for my $i (1..$top) {
            push @args, $lua->tostring($i) || '';
        }
        my $output = join("\t", @args);
        $lua->pushstring($output);
        return 1;
    });

    # Set up the rpm table functions
    $self->{lua}->dostring(q{
        rpm.expand = __rpm_expand
        rpm.getvar = __rpm_getvar
        rpm.setvar = __rpm_setvar
    });
}

# Set up security sandbox
sub _setup_sandbox {
    my ($self) = @_;

    # Disable dangerous functions
    $self->{lua}->dostring(q{
        -- Disable file I/O
        io = nil
        file = nil

        -- Disable system functions
        os.execute = nil
        os.exit = nil
        os.remove = nil
        os.rename = nil
        os.tmpname = nil

        -- Disable loading
        require = nil
        dofile = nil
        loadfile = nil
        load = nil
        loadstring = nil

        -- Disable module system
        module = nil
        package = nil
    });
}

# RPM macro expansion
sub _rpm_expand {
    my ($self, $macro) = @_;

    return '' unless $self->{rpm_context};

    # Get current macros context
    my $macros = $self->{rpm_context}->{macros} || {};
    my $config = $self->{rpm_context}->{config} || $self->{config};

    # Clean the macro name
    my $clean_macro = $macro;
    $clean_macro =~ s/^%//;

    # Direct macro lookup first (avoid recursion)
    if (ref($macros) eq 'HASH' && exists $macros->{$clean_macro}) {
        return $macros->{$clean_macro};
    }

    # Debug: log macro access for troubleshooting
    if ($ENV{BUILD_DEBUG} && $clean_macro eq 'arch') {
        warn "DEBUG: Looking for macro '$clean_macro', available macros: " .
             join(", ", grep {/arch/} sort keys %$macros) . "\n";
    }

    # Built-in macro handling - use the actual builtin macro system
    if ($config) {
        # Try builtin macros first
        eval {
            my $builtin_result = Build::Rpm::builtinmacro($config, $macros, $clean_macro);
            return $builtin_result if defined $builtin_result && $builtin_result ne '';
        };
        if ($@) {
            warn "Error calling builtin macro: $@" if $ENV{BUILD_DEBUG};
        }

        # Fallback to direct config values
        return $config->{arch} || 'x86_64' if $clean_macro eq '_arch' || $clean_macro eq 'arch';
        return $config->{arch} || 'x86_64' if $clean_macro eq '_target_cpu';
        return 'linux' if $clean_macro eq '_target_os';
    }
    return '' if $clean_macro eq '_dist' || $clean_macro eq 'dist';

    # For complex macros that might need expansion, use Build::Rpm::expandmacros
    # but only if we're not already in a macro expansion to avoid recursion
    if ($config && ref($macros) eq 'HASH' && !$self->{_in_expansion}) {
        local $self->{_in_expansion} = 1;  # Prevent recursion
        eval {
            my $expanded = Build::Rpm::expandmacros($config, $macro, $macros, {});
            return $expanded if defined $expanded && $expanded ne $macro;
        };
        if ($@) {
            warn "Error in _rpm_expand: $@" if $ENV{BUILD_DEBUG};
        }
    }

    return '';
}

# Get RPM variable
sub _rpm_getvar {
    my ($self, $name) = @_;

    return '' unless $self->{rpm_context} && $self->{rpm_context}->{macros};

    my $macros = $self->{rpm_context}->{macros};
    return $macros->{$name} || '';
}

# Set RPM variable
sub _rpm_setvar {
    my ($self, $name, $value) = @_;

    return unless $self->{rpm_context} && $self->{rpm_context}->{macros};

    $self->{rpm_context}->{macros}->{$name} = $value;
}

1;

__END__

=head1 SEE ALSO

L<Build::Rpm>, L<Lua::API>

=head1 AUTHOR

OBS Build System Enhancement Project

=cut
