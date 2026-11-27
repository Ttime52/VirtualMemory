#!/usr/bin/env bash

set -u

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
cli="$script_dir/../scripts/vm_monitor.sh"
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/vm_monitor_cli_test.XXXXXXXX") || exit 1
trap 'rm -rf -- "$tmp_dir"' EXIT

fail()
{
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

run_case()
{
    local label=$1
    local expected_status=$2
    shift 2
    local actual_status

    bash "$cli" "$@" >"$tmp_dir/stdout" 2>"$tmp_dir/stderr"
    actual_status=$?
    if (( actual_status != expected_status )); then
        printf 'stdout:\n' >&2
        cat "$tmp_dir/stdout" >&2
        printf 'stderr:\n' >&2
        cat "$tmp_dir/stderr" >&2
        fail "$label: expected status $expected_status, got $actual_status"
    fi
    printf 'PASS: %s\n' "$label"
}

expect_text()
{
    local label=$1
    local file=$2
    local text=$3
    grep -Fq -- "$text" "$file" || fail "$label: expected text was not printed: $text"
}

[[ -f $cli ]] || fail "CLI script not found: $cli"

run_case "help" 0 --help
expect_text "help" "$tmp_dir/stdout" "Usage: sudo ./scripts/vm_monitor.sh <PID>"

run_case "missing PID" 2
expect_text "missing PID" "$tmp_dir/stderr" "exactly one PID is required"

run_case "non-numeric PID" 2 abc
expect_text "non-numeric PID" "$tmp_dir/stderr" "PID must be a positive integer"

run_case "zero PID" 2 0
run_case "negative PID" 2 -12
run_case "fractional PID" 2 12.5
run_case "PID above signed int range" 2 2147483648
run_case "extra arguments" 2 123 extra
expect_text "extra arguments" "$tmp_dir/stderr" "exactly one PID is required"

# The script resolves the module relative to its own path, not the caller's cwd.
if (cd -- "$tmp_dir" && bash "$cli" --help >"$tmp_dir/cwd.stdout" 2>"$tmp_dir/cwd.stderr"); then
    expect_text "invocation from another directory" "$tmp_dir/cwd.stdout" "Usage:"
    printf 'PASS: invocation from another directory\n'
else
    cat "$tmp_dir/cwd.stderr" >&2
    fail "invocation from another directory"
fi

# A valid PID must reach the environment checks without loading any module.
if [[ $(uname -s) == Linux ]] && (( EUID != 0 )); then
    run_case "valid PID rejected without root" 77 0001
    expect_text "valid PID rejected without root" "$tmp_dir/stderr" "root privileges are required"
else
    printf 'SKIP: valid-PID privilege check requires a non-root Linux shell\n'
fi

printf 'CLI argument checks completed. No kernel module was loaded.\n'
