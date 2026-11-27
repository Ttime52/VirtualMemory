#!/usr/bin/env bash

set -u
set -o pipefail
export LC_ALL=C

readonly MODULE_NAME="vm_monitor"
readonly MAX_PID="2147483647"
readonly LOCK_FILE="/run/lock/vm_monitor.lock"

usage()
{
    cat <<'EOF'
Usage: sudo ./scripts/vm_monitor.sh <PID>
       ./scripts/vm_monitor.sh --help

Take one virtual-memory statistics snapshot using the vm_monitor kernel module.
The module must be built for the currently running Linux kernel.

Options:
  -h, --help  Show this help without requiring root privileges.

The reported page-fault counters are cumulative process counters. The wrapper
uses flock to serialize its own invocations; it cannot coordinate with manual
insmod or rmmod commands.
EOF
}

error()
{
    local status=$1
    shift
    printf 'Error: %s\n' "$*" >&2
    exit "$status"
}

if [[ $# -eq 1 && ( $1 == "--help" || $1 == "-h" ) ]]; then
    usage
    exit 0
fi

if [[ $# -ne 1 ]]; then
    printf 'Error: exactly one PID is required.\n' >&2
    usage >&2
    exit 2
fi

raw_pid=$1
if [[ ! $raw_pid =~ ^[0-9]+$ ]]; then
    printf 'Error: PID must be a positive integer.\n' >&2
    printf 'Usage: sudo ./scripts/vm_monitor.sh <PID>\n' >&2
    exit 2
fi

# Remove leading zeroes before doing arithmetic or a range comparison.
pid=$(printf '%s\n' "$raw_pid" | sed 's/^0*//')
pid=${pid:-0}
if [[ $pid == 0 ]]; then
    printf 'Error: PID must be a positive integer.\n' >&2
    printf 'Usage: sudo ./scripts/vm_monitor.sh <PID>\n' >&2
    exit 2
fi
if (( ${#pid} > 10 )) || { (( ${#pid} == 10 )) && [[ $pid > "$MAX_PID" ]]; }; then
    error 2 "PID exceeds the supported integer range (1-$MAX_PID)."
fi

if [[ $(uname -s) != Linux ]]; then
    error 1 "this command is intended to run on Linux."
fi
if (( EUID != 0 )); then
    error 77 "root privileges are required; run with sudo."
fi

for command_name in insmod rmmod dmesg flock grep sed awk mktemp sleep; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        error 1 "required command not found: $command_name."
    fi
done

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || \
    error 1 "could not resolve the script directory."
repo_root=$(cd -- "$script_dir/.." && pwd -P) || \
    error 1 "could not resolve the repository directory."
module_path="$repo_root/kernel/vm_monitor.ko"

if [[ ! -f $module_path ]]; then
    printf 'Error: kernel module not found: %s\n' "$module_path" >&2
    printf 'Build the module first using:\n\n    make -C kernel\n' >&2
    exit 1
fi

if command -v modinfo >/dev/null 2>&1; then
    module_vermagic=$(modinfo -F vermagic "$module_path" 2>/dev/null || true)
    if [[ -n $module_vermagic ]]; then
        module_kernel=${module_vermagic%% *}
        running_kernel=$(uname -r)
        if [[ $module_kernel != "$running_kernel" ]]; then
            printf 'Error: module vermagic is for kernel %s, but the running kernel is %s.\n' \
                "$module_kernel" "$running_kernel" >&2
            printf 'Rebuild using headers for the running kernel:\n\n    make -C kernel\n' >&2
            exit 1
        fi
    fi
fi

if ! exec {lock_fd}>"$LOCK_FILE"; then
    error 1 "could not open the CLI lock file: $LOCK_FILE."
fi
if ! flock -n "$lock_fd"; then
    error 73 "another vm_monitor CLI invocation is already running."
fi

if [[ -e "/sys/module/$MODULE_NAME" ]]; then
    error 1 "the $MODULE_NAME module is already loaded; refusing to remove a module owned by another command."
fi

umask 077
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/vm_monitor.XXXXXXXX") || \
    error 1 "could not create a private temporary directory."
kernel_log="$tmp_dir/kernel.log"
normalized_log="$tmp_dir/kernel.normalized.log"
dmesg_error="$tmp_dir/dmesg.err"
insmod_error="$tmp_dir/insmod.err"
rmmod_error="$tmp_dir/rmmod.err"
log_reader_pid=""
module_owned=0
signal_status=0

stop_log_reader()
{
    if [[ -n $log_reader_pid ]]; then
        kill "$log_reader_pid" >/dev/null 2>&1 || true
        wait "$log_reader_pid" >/dev/null 2>&1 || true
        log_reader_pid=""
    fi
}

cleanup()
{
    local status=$?
    trap - EXIT
    stop_log_reader

    if (( module_owned )); then
        if rmmod "$MODULE_NAME" 2>"$rmmod_error"; then
            module_owned=0
        else
            printf 'Error: could not unload the module during cleanup.\n' >&2
            if [[ -s $rmmod_error ]]; then
                cat "$rmmod_error" >&2
            fi
            status=1
        fi
    fi

    rm -f -- "$kernel_log" "$normalized_log" "$dmesg_error" \
        "$insmod_error" "$rmmod_error" 2>/dev/null || status=1
    rmdir -- "$tmp_dir" 2>/dev/null || status=1
    exit "$status"
}

trap cleanup EXIT
trap 'signal_status=130' INT
trap 'signal_status=143' TERM
trap 'signal_status=129' HUP

show_module_log()
{
    if [[ -s $normalized_log ]]; then
        grep -F 'vm_monitor:' "$normalized_log" || true
    fi
}

normalize_log()
{
    sed -E 's/^<[0-9]+>//' "$kernel_log" >"$normalized_log"
}

check_for_signal()
{
    if (( signal_status != 0 )); then
        printf 'Error: interrupted; attempting safe module cleanup.\n' >&2
        exit "$signal_status"
    fi
}

printf 'Capturing a kernel-log boundary and starting the snapshot for PID %s...\n' "$pid"
# --follow-new starts at the current end of the kernel log, so older records
# cannot be mistaken for this invocation's output. Never clear the system log.
dmesg --follow-new --raw >"$kernel_log" 2>"$dmesg_error" &
log_reader_pid=$!
sleep 0.1
check_for_signal

if ! kill -0 "$log_reader_pid" 2>/dev/null || [[ -s $dmesg_error ]]; then
    stop_log_reader
    printf 'Error: cannot follow new kernel log messages.\n' >&2
    if [[ -s $dmesg_error ]]; then
        cat "$dmesg_error" >&2
    fi
    error 1 "check dmesg permissions and /dev/kmsg availability."
fi

# Keep the signal handler non-terminating around insmod. If Ctrl+C arrives
# while insertion is in progress, wait for insmod's result so ownership can be
# recorded before the EXIT cleanup runs.
if insmod "$module_path" "pid=$pid" 2>"$insmod_error"; then
    module_owned=1
else
    insmod_status=$?
    stop_log_reader
    normalize_log || true

    if grep -Fq "vm_monitor: PID $pid was not found" "$normalized_log"; then
        printf 'Error: process %s was not found.\n' "$pid" >&2
    elif grep -Fq "vm_monitor: process for PID $pid was not found" "$normalized_log"; then
        printf 'Error: process %s exited before it could be inspected.\n' "$pid" >&2
    elif grep -Fq "vm_monitor: PID $pid has no accessible user address space" "$normalized_log"; then
        printf 'Error: process %s has no accessible user address space or exited during inspection.\n' "$pid" >&2
    else
        printf 'Error: kernel module insertion failed (insmod exit status %s).\n' "$insmod_status" >&2
    fi

    if [[ -s $insmod_error ]]; then
        cat "$insmod_error" >&2
    fi
    show_module_log >&2
    if grep -Fqi 'wrong symbol version' "$insmod_error"; then
        printf '%s\n' "Note: kmod may use this wording for an -ESRCH module-init error; check the vm_monitor kernel message above before diagnosing a version mismatch." >&2
    fi
    if [[ -e "/sys/module/$MODULE_NAME" ]]; then
        printf '%s\n' "The module appeared in /sys/module despite insmod failing; it was not removed because this invocation cannot confirm ownership." >&2
    fi
    exit 1
fi

check_for_signal
if [[ ! -e "/sys/module/$MODULE_NAME" ]]; then
    error 1 "insmod succeeded but the module is not present in /sys/module."
fi

log_has_snapshot_fields()
{
    normalize_log || return 1
    grep -Fq "vm_monitor: target PID = $pid, process name = " "$normalized_log" &&
        grep -Fq 'vm_monitor: number of memory regions = ' "$normalized_log" &&
        grep -Fq 'vm_monitor: total virtual address space = ' "$normalized_log" &&
        grep -Fq 'vm_monitor: process minor page faults = ' "$normalized_log" &&
        grep -Fq 'vm_monitor: process major page faults = ' "$normalized_log"
}

snapshot_found=0
for ((attempt = 0; attempt < 30; attempt++)); do
    check_for_signal
    if log_has_snapshot_fields; then
        snapshot_found=1
        break
    fi
    if [[ -s $dmesg_error ]] || ! kill -0 "$log_reader_pid" 2>/dev/null; then
        break
    fi
    sleep 0.1
done

if (( ! snapshot_found )); then
    stop_log_reader
    normalize_log || true
    printf 'Error: complete statistics for PID %s were not received from the kernel log.\n' "$pid" >&2
    if [[ -s $dmesg_error ]]; then
        cat "$dmesg_error" >&2
    fi
    show_module_log >&2
    error 1 "no success summary will be displayed; the module will be cleaned up."
fi

stop_log_reader
check_for_signal
if ! normalize_log; then
    show_module_log >&2
    error 1 "could not parse the captured kernel log."
fi

target_prefix="vm_monitor: target PID = $pid, process name = "
target_line_count=0
all_target_line_count=0
module_line_count=0
process_name=""
while IFS= read -r line || [[ -n $line ]]; do
    [[ $line == vm_monitor:* ]] || continue
    module_line_count=$((module_line_count + 1))
    if [[ $line == 'vm_monitor: target PID = '* ]]; then
        all_target_line_count=$((all_target_line_count + 1))
        if [[ $line == "$target_prefix"* ]]; then
            target_line_count=$((target_line_count + 1))
            process_name=${line#"$target_prefix"}
        fi
    fi
done <"$normalized_log"

if (( module_line_count != 5 || all_target_line_count != 1 || target_line_count != 1 )); then
    printf 'Error: kernel log output is incomplete or ambiguous for PID %s.\n' "$pid" >&2
    show_module_log >&2
    error 1 "expected one target record and exactly four metric records."
fi

parse_numeric_field()
{
    local field_prefix=$1
    local variable_name=$2
    local count=0
    local value=""
    local line

    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line == "$field_prefix"* ]]; then
            count=$((count + 1))
            value=${line#"$field_prefix"}
        fi
    done <"$normalized_log"

    if (( count != 1 )) || [[ ! $value =~ ^[0-9]+$ ]]; then
        printf 'Error: missing, duplicate, or malformed kernel statistic: %s\n' \
            "${field_prefix#vm_monitor: }" >&2
        return 1
    fi

    printf -v "$variable_name" '%s' "$value"
}

if ! parse_numeric_field 'vm_monitor: number of memory regions = ' region_count ||
    ! parse_numeric_field 'vm_monitor: total virtual address space = ' virtual_bytes_raw ||
    ! parse_numeric_field 'vm_monitor: process minor page faults = ' minor_faults ||
    ! parse_numeric_field 'vm_monitor: process major page faults = ' major_faults; then
    show_module_log >&2
    error 1 "the kernel snapshot could not be validated."
fi

if ! kib=$(awk -v bytes="$virtual_bytes_raw" 'BEGIN { printf "%.2f", bytes / 1024 }') ||
    ! mib=$(awk -v bytes="$virtual_bytes_raw" 'BEGIN { printf "%.2f", bytes / 1048576 }'); then
    error 1 "could not convert the virtual address size to binary units."
fi

check_for_signal
if ! rmmod "$MODULE_NAME" 2>"$rmmod_error"; then
    printf 'Error: could not unload the %s module.\n' "$MODULE_NAME" >&2
    if [[ -s $rmmod_error ]]; then
        cat "$rmmod_error" >&2
    fi
    error 1 "the module remains owned by this invocation; cleanup will retry."
fi
module_owned=0
check_for_signal

printf '\n========================================\n'
printf '        Virtual Memory Monitor\n'
printf '========================================\n\n'
printf 'Snapshot              : Kernel module initialization\n'
printf 'Process ID            : %s\n' "$pid"
printf 'Process Name          : %s\n\n' "$process_name"
printf 'Memory Regions        : %s\n' "$region_count"
printf 'Virtual Address Space : %s bytes\n' "$virtual_bytes_raw"
printf '                        %s KiB\n' "$kib"
printf '                        %s MiB\n\n' "$mib"
printf 'Minor Page Faults     : %s (cumulative)\n' "$minor_faults"
printf 'Major Page Faults     : %s (cumulative)\n\n' "$major_faults"
printf '========================================\n'
printf 'Status: Completed successfully\n'
printf '========================================\n'
