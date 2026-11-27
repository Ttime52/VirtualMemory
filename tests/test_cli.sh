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

expect_parse_failure()
{
    local label=$1
    local file=$2
    local pid=$3

    if vm_monitor_parse_snapshot "$file" "$pid"; then
        fail "$label: malformed or ambiguous kernel log was accepted"
    fi
    printf 'PASS: %s\n' "$label"
}

expect_value()
{
    local label=$1
    local actual=$2
    local expected=$3

    [[ $actual == "$expected" ]] || fail "$label: expected '$expected', got '$actual'"
}

[[ -f $cli ]] || fail "CLI script not found: $cli"
source "$script_dir/../scripts/vm_monitor_log.sh" || fail "kernel-log parser not found"

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

# Help is available from another directory without requiring module access.
if (cd -- "$tmp_dir" && bash "$cli" --help >"$tmp_dir/cwd.stdout" 2>"$tmp_dir/cwd.stderr"); then
    expect_text "help from another directory" "$tmp_dir/cwd.stdout" "Usage:"
    printf 'PASS: help from another directory\n'
else
    cat "$tmp_dir/cwd.stderr" >&2
    fail "help from another directory"
fi

# A valid PID must reach the environment checks without loading any module.
if [[ $(uname -s) == Linux ]] && (( EUID != 0 )); then
    run_case "valid PID rejected without root" 77 0001
    expect_text "valid PID rejected without root" "$tmp_dir/stderr" "root privileges are required"
else
    printf 'SKIP: valid-PID privilege check requires a non-root Linux shell\n'
fi

cat >"$tmp_dir/kernel.raw" <<'EOF'
<6>[  12.340001] vm_monitor: target PID = 4242, process name = test_major
[  12.340002] <6>vm_monitor: number of memory regions = 27
<6>[  12.340003] vm_monitor: total virtual address space = 70881280 bytes
[  12.340004] <6>vm_monitor: process minor page faults = 1375
<6>[  12.340005] vm_monitor: process major page faults = 0
<4>[  12.340006] vm_monitor: module verification failed: signature and/or required key missing - tainting kernel
EOF

vm_monitor_normalize_log "$tmp_dir/kernel.raw" "$tmp_dir/kernel.normalized" || \
    fail "could not normalize the kernel-log fixture"
vm_monitor_parse_snapshot "$tmp_dir/kernel.normalized" 4242 || \
    fail "timestamped log with an extra module diagnostic was rejected: $VM_PARSE_ERROR"
expect_value "parsed target name" "$VM_PROCESS_NAME" "test_major"
expect_value "parsed region count" "$VM_REGION_COUNT" "27"
expect_value "parsed virtual bytes" "$VM_VIRTUAL_BYTES" "70881280"
expect_value "parsed minor faults" "$VM_MINOR_FAULTS" "1375"
expect_value "parsed major faults" "$VM_MAJOR_FAULTS" "0"
vm_monitor_format_summary 4242 >"$tmp_dir/summary" || \
    fail "complete output-format fixture did not reach the success summary"
expect_text "formatted output" "$tmp_dir/summary" "Status: Completed successfully"
expect_text "formatted output" "$tmp_dir/summary" "Virtual Address Space : 70881280 bytes"
expect_text "formatted output" "$tmp_dir/summary" "69220.00 KiB"
expect_text "formatted output" "$tmp_dir/summary" "67.60 MiB"
printf 'PASS: timestamped records and extra module diagnostic\n'

grep -Fv 'process major page faults' "$tmp_dir/kernel.normalized" >"$tmp_dir/missing.log"
expect_parse_failure "missing statistic" "$tmp_dir/missing.log" 4242

cat "$tmp_dir/kernel.normalized" >"$tmp_dir/duplicate.log"
printf '%s\n' 'vm_monitor: process major page faults = 1' >>"$tmp_dir/duplicate.log"
expect_parse_failure "duplicate statistic" "$tmp_dir/duplicate.log" 4242

sed 's/target PID = 4242/target PID = 4243/' "$tmp_dir/kernel.normalized" >"$tmp_dir/wrong-pid.log"
expect_parse_failure "target PID mismatch" "$tmp_dir/wrong-pid.log" 4242

{
    printf '%s\n' 'vm_monitor: target PID = 1111, process name = stale'
    cat "$tmp_dir/kernel.normalized"
} >"$tmp_dir/stale.log"
expect_parse_failure "stale or mixed target record" "$tmp_dir/stale.log" 4242

sed 's/70881280 bytes/70881280/' "$tmp_dir/kernel.normalized" >"$tmp_dir/malformed-bytes.log"
expect_parse_failure "malformed byte field" "$tmp_dir/malformed-bytes.log" 4242

printf 'CLI argument and kernel-log parsing checks completed. No kernel module was loaded.\n'
