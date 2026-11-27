#!/bin/sh

# Run only in a disposable Linux VM as root. This script tests module
# parameter rejection, failed-init cleanup, and repeated load/unload.

set -eu

module=${1:-kernel/vm_monitor.ko}
module_name=vm_monitor
owned_module=0

fail()
{
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

module_loaded()
{
    [ -d "/sys/module/$module_name" ]
}

cleanup()
{
    if [ "$owned_module" -eq 1 ] && module_loaded; then
        rmmod "$module_name" || true
    fi
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[ "$(uname -s)" = Linux ] || fail "Linux is required"
[ "$(id -u)" -eq 0 ] || fail "run this script as root in a disposable VM"
[ "${VM_SAFETY_ACK:-}" = YES ] || fail "set VM_SAFETY_ACK=YES only in a disposable or snapshotted VM"
[ -r "$module" ] || fail "module file not found: $module"
command -v insmod >/dev/null 2>&1 || fail "insmod is unavailable"
command -v rmmod >/dev/null 2>&1 || fail "rmmod is unavailable"
command -v modinfo >/dev/null 2>&1 || fail "modinfo is unavailable"

if module_loaded; then
    fail "$module_name is already loaded; refusing to interfere with it"
fi

vermagic=$(modinfo -F vermagic "$module") || fail "could not read module vermagic"
module_kernel=${vermagic%% *}
[ "$module_kernel" = "$(uname -r)" ] || fail "module vermagic does not match $(uname -r)"

expect_rejected()
{
    label=$1
    shift

    if insmod "$module" "$@"; then
        owned_module=1
        fail "$label unexpectedly loaded the module"
    fi

    if module_loaded; then
        # A failed insmod does not prove that this test loaded the module.
        # It may have appeared due to an external/manual insertion, so leave
        # it untouched and let the operator resolve the unexpected state.
        fail "$label failed and $module_name is present; ownership is unknown, leaving it loaded"
    fi

    printf 'PASS: %s rejected; module is not loaded\n' "$label"
}

# First prove that this .ko can load on the running kernel. This prevents a
# vermagic/symbol mismatch from making all the negative cases look successful.
iteration=1
while [ "$iteration" -le 5 ]; do
    insmod "$module" "pid=$$" || fail "valid PID load failed on iteration $iteration"
    owned_module=1
    module_loaded || fail "valid load did not appear in /sys/module"
    rmmod "$module_name" || fail "rmmod failed on iteration $iteration"
    if module_loaded; then
        fail "module remained loaded after rmmod"
    fi
    owned_module=0
    printf 'PASS: valid PID load/unload %s/5\n' "$iteration"
    iteration=$((iteration + 1))
done

expect_rejected "missing PID"
expect_rejected "PID zero" "pid=0"
expect_rejected "negative PID" "pid=-7"
expect_rejected "non-numeric PID" "pid=not-a-number"
expect_rejected "PID above signed int range" "pid=2147483648"
expect_rejected "nonexistent PID" "pid=99999999"

printf '%s\n' "Safety parameter and lifecycle checks completed."
printf '%s\n' "Inspect the kernel log for each vm_monitor rejection reason."
