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

for command_name in insmod rmmod dmesg flock grep sed awk mktemp sleep readlink wc setsid; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        error 1 "required command not found: $command_name."
    fi
done

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || \
    error 1 "could not resolve the script directory."
repo_root=$(cd -- "$script_dir/.." && pwd -P) || \
    error 1 "could not resolve the repository directory."
module_path="$repo_root/kernel/vm_monitor.ko"
log_parser="$script_dir/vm_monitor_log.sh"

if [[ ! -f $log_parser ]]; then
    error 1 "kernel-log parser not found: $log_parser."
fi
source "$log_parser" || error 1 "could not load the kernel-log parser."

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
boundary_error="$tmp_dir/boundary.err"
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
        "$boundary_error" "$insmod_error" "$rmmod_error" 2>/dev/null || status=1
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
    vm_monitor_normalize_log "$kernel_log" "$normalized_log"
}

log_reader_is_running()
{
    local stat_line stat_rest state

    [[ -n $log_reader_pid && -r /proc/$log_reader_pid/stat ]] || return 1
    IFS= read -r stat_line <"/proc/$log_reader_pid/stat" || return 1
    stat_rest=${stat_line#*) }
    state=${stat_rest%% *}
    [[ $state != Z && $state != X ]]
}

log_reader_has_kernel_fd()
{
    local fd fd_target

    for fd in "/proc/$log_reader_pid/fd/"*; do
        [[ -e $fd ]] || continue
        fd_target=$(readlink -- "$fd" 2>/dev/null || true)
        if [[ $fd_target == /dev/kmsg || $fd_target == /proc/kmsg ]]; then
            return 0
        fi
    done
    return 1
}

wait_for_log_reader()
{
    local attempt

    for ((attempt = 0; attempt < 50; attempt++)); do
        check_for_signal
        [[ ! -s $dmesg_error ]] || return 1
        log_reader_is_running || return 1
        log_reader_has_kernel_fd && return 0
        sleep 0.1
    done
    return 1
}

establish_log_boundary()
{
    local attempt marker_attempt

    # Seeing the marker in the follower proves it has opened the kernel log
    # and is consuming new records. Retry with fresh tokens if startup races
    # the first write; do not insert the module until one marker is observed.
    for ((marker_attempt = 0; marker_attempt < 5; marker_attempt++)); do
        check_for_signal
        boundary_marker="vm_monitor_cli_boundary: pid=$pid token=$$-$RANDOM-$RANDOM"
        if ! { printf '<6>%s\n' "$boundary_marker" > /dev/kmsg; } 2>"$boundary_error"; then
            return 2
        fi

        for ((attempt = 0; attempt < 10; attempt++)); do
            check_for_signal
            normalize_log || return 1
            grep -Fq -- "$boundary_marker" "$normalized_log" && return 0
            [[ ! -s $dmesg_error ]] || return 1
            log_reader_is_running || return 1
            sleep 0.1
        done
    done
    return 1
}

drain_log_reader()
{
    local attempt previous_size="" current_size stable_reads=0

    # insmod returns after module_init has logged its error, but dmesg may not
    # have copied those records into the redirected file yet. Wait for a short
    # quiet period before stopping the reader, with a bounded timeout.
    for ((attempt = 0; attempt < 30; attempt++)); do
        [[ ! -s $dmesg_error ]] || break
        log_reader_is_running || break
        current_size=$(wc -c <"$kernel_log" 2>/dev/null) || break
        current_size=${current_size//[[:space:]]/}
        if [[ $current_size == "$previous_size" ]]; then
            stable_reads=$((stable_reads + 1))
        else
            stable_reads=0
        fi
        (( stable_reads >= 2 )) && break
        previous_size=$current_size
        sleep 0.1
    done
}

check_for_signal()
{
    if (( signal_status != 0 )); then
        printf 'Error: interrupted; attempting safe module cleanup.\n' >&2
        exit "$signal_status"
    fi
}

printf 'Capturing a kernel-log boundary and starting the snapshot for PID %s...\n' "$pid"
# --follow-new starts at the current end of the kernel log. Confirm the reader
# has opened the kernel log and can receive a unique marker before insmod; a
# fixed startup sleep alone cannot establish that boundary. Never clear logs.
dmesg --follow-new --raw --notime >"$kernel_log" 2>"$dmesg_error" &
log_reader_pid=$!
if ! wait_for_log_reader; then
    stop_log_reader
    printf 'Error: kernel-log reader did not become ready.\n' >&2
    if [[ -s $dmesg_error ]]; then
        cat "$dmesg_error" >&2
    fi
    error 1 "check dmesg permissions, /dev/kmsg availability, and /proc access."
fi

# Wait until a unique kernel-log marker is actually consumed. This confirms
# the follow-new reader's boundary before the module can emit its snapshot.
if ! establish_log_boundary; then
    stop_log_reader
    printf 'Error: could not confirm the kernel-log boundary.\n' >&2
    if [[ -s $dmesg_error ]]; then
        cat "$dmesg_error" >&2
    fi
    if [[ -s $boundary_error ]]; then
        cat "$boundary_error" >&2
    fi
    error 1 "the module was not loaded because fresh-log capture is unavailable."
fi

# setsid keeps the insmod child out of the terminal's Ctrl+C process group.
# The wrapper records ownership after setsid returns, then handles a pending
# signal so EXIT cleanup can unload only a confirmed successful insertion.
if setsid --wait insmod "$module_path" "pid=$pid" 2>"$insmod_error"; then
    module_owned=1
else
    insmod_status=$?
    drain_log_reader
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
    if [[ -s $dmesg_error ]]; then
        printf 'Kernel-log reader diagnostics:\n' >&2
        cat "$dmesg_error" >&2
    fi
    show_module_log >&2
    if grep -Fqi 'wrong symbol version' "$insmod_error"; then
        printf '%s\n' "Note: kmod may use this wording for an -ESRCH module-init error; check the vm_monitor kernel message above before diagnosing a version mismatch." >&2
    fi
    if [[ -e "/sys/module/$MODULE_NAME" ]]; then
        printf '%s\n' "The module appeared in /sys/module despite insmod failing; it was not removed because this invocation cannot confirm ownership." >&2
    fi
    if (( signal_status != 0 )); then
        exit "$signal_status"
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
    vm_monitor_parse_snapshot "$normalized_log" "$pid"
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

if ! vm_monitor_parse_snapshot "$normalized_log" "$pid"; then
    printf 'Error: kernel log output is incomplete or ambiguous for PID %s.\n' "$pid" >&2
    if [[ -n $VM_PARSE_ERROR ]]; then
        printf 'Detail: %s.\n' "$VM_PARSE_ERROR" >&2
    fi
    show_module_log >&2
    error 1 "the kernel snapshot could not be validated."
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

if ! vm_monitor_format_summary "$pid"; then
    error 1 "could not format the validated kernel snapshot."
fi
