#!/usr/bin/perl

use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempfile);

my $root = "$FindBin::Bin/..";
$ENV{BUILD_DIR} = $root;

my ($fh, $script) = tempfile();

print $fh <<'SH';
#!/bin/bash

ROOT="$1"

cleanup_and_exit() {
    exit "${1:-1}"
}

needarg() {
    test -n "$ARG"
}

source "$ROOT/build-vm"

PARAM="--vm-network"
ARG="/tmp/kernel-default.spec"

set -- "/tmp/kernel-default.spec"

vm_parse_options "$@"

printf 'VM_NETWORK=%s\n' "$VM_NETWORK"
printf 'NEXTARGS=%s\n' "${#nextargs[@]}"
printf 'NEXTARG=%s\n' "${nextargs[0]-}"
SH

close $fh;

my $output = `bash "$script" "$root"`;
my $exit_code = $? >> 8;

is($exit_code, 0, 'vm_parse_options succeeds');
like($output, qr/^VM_NETWORK=true$/m, '--vm-network enables VM networking');
like($output, qr/^NEXTARGS=1$/m, '--vm-network does not consume the next argument');
like(
    $output,
    qr{^NEXTARG=/tmp/kernel-default\.spec$}m,
    'recipe argument is preserved'
);

done_testing();
