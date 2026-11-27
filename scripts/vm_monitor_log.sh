#!/usr/bin/env bash

# Shared log parsing helpers. Kept separate so tests can exercise the same
# normalization and validation paths used by vm_monitor.sh.

vm_monitor_normalize_log()
{
    local raw_file=$1
    local normalized_file=$2

    # dmesg versions and options can place the priority and timestamp in
    # either order. Strip both; --notime is also requested by the CLI.
    sed -E \
        -e 's/^<[0-9]+>[[:space:]]*//' \
        -e 's/^\[[^]]+\][[:space:]]*//' \
        -e 's/^<[0-9]+>[[:space:]]*//' \
        "$raw_file" >"$normalized_file"
}

vm_monitor_parse_snapshot()
{
    local normalized_file=$1
    local expected_pid=$2
    local expected_target_prefix="vm_monitor: target PID = $expected_pid, process name = "
    local line value
    local target_count=0
    local matching_target_count=0
    local region_count=0
    local byte_count=0
    local minor_count=0
    local major_count=0
    local malformed_field=""

    VM_PROCESS_NAME=""
    VM_REGION_COUNT=""
    VM_VIRTUAL_BYTES=""
    VM_MINOR_FAULTS=""
    VM_MAJOR_FAULTS=""
    VM_PARSE_ERROR=""

    while IFS= read -r line || [[ -n $line ]]; do
        case $line in
            'vm_monitor: target PID = '*)
                target_count=$((target_count + 1))
                if [[ $line == "$expected_target_prefix"* ]]; then
                    matching_target_count=$((matching_target_count + 1))
                    VM_PROCESS_NAME=${line#"$expected_target_prefix"}
                fi
                ;;
            'vm_monitor: number of memory regions = '*)
                region_count=$((region_count + 1))
                value=${line#'vm_monitor: number of memory regions = '}
                if [[ $value =~ ^[0-9]+$ ]]; then
                    VM_REGION_COUNT=$value
                else
                    malformed_field="number of memory regions"
                fi
                ;;
            'vm_monitor: total virtual address space = '*)
                byte_count=$((byte_count + 1))
                value=${line#'vm_monitor: total virtual address space = '}
                if [[ $value =~ ^([0-9]+)[[:space:]]+bytes$ ]]; then
                    VM_VIRTUAL_BYTES=${BASH_REMATCH[1]}
                else
                    malformed_field="total virtual address space"
                fi
                ;;
            'vm_monitor: process minor page faults = '*)
                minor_count=$((minor_count + 1))
                value=${line#'vm_monitor: process minor page faults = '}
                if [[ $value =~ ^[0-9]+$ ]]; then
                    VM_MINOR_FAULTS=$value
                else
                    malformed_field="process minor page faults"
                fi
                ;;
            'vm_monitor: process major page faults = '*)
                major_count=$((major_count + 1))
                value=${line#'vm_monitor: process major page faults = '}
                if [[ $value =~ ^[0-9]+$ ]]; then
                    VM_MAJOR_FAULTS=$value
                else
                    malformed_field="process major page faults"
                fi
                ;;
        esac
    done <"$normalized_file"

    if (( target_count != 1 || matching_target_count != 1 )); then
        VM_PARSE_ERROR="expected exactly one target record for PID $expected_pid"
        return 1
    fi
    if (( region_count != 1 || byte_count != 1 || minor_count != 1 || major_count != 1 )); then
        VM_PARSE_ERROR="expected exactly one record for each of the four statistics"
        return 1
    fi
    if [[ -n $malformed_field ]]; then
        VM_PARSE_ERROR="malformed numeric value for $malformed_field"
        return 1
    fi

    return 0
}
