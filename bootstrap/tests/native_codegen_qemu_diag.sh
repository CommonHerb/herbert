#!/usr/bin/env bash

native_codegen_qemu_exit_low7_hex() {
    local rc="$1" payload
    case "$rc" in
        ''|*[!0-9]*) printf 'n/a\n'; return 0 ;;
    esac
    if [[ "$rc" -eq 124 || "$rc" -eq 0 || $((rc % 2)) -eq 0 ]]; then
        printf 'n/a\n'
        return 0
    fi
    payload=$(( ((rc >> 1) ^ 0x31) & 0x7f ))
    printf '0x%02x\n' "$payload"
}

native_codegen_e9_hex() {
    local out="$1" hex
    if [[ ! -f "$out" ]]; then
        printf '<missing>\n'
        return 0
    fi
    hex="$(xxd -p "$out" 2>/dev/null | tr -d '\n')"
    if [[ -z "$hex" ]]; then
        printf '<empty>\n'
        return 0
    fi
    printf '%s\n' "$hex"
}

native_codegen_join_lines() {
    awk 'BEGIN { first = 1 } { if (!first) printf " | "; printf "%s", $0; first = 0 }'
}

native_codegen_grade_detail() {
    local ref="$1" out="$2" kend="$3" fed_hex="$4" kind="$5"
    local detail rc
    detail="$(python3 "$ref" grade "$out" "$kend" "$fed_hex" "$kind" 2>&1)"
    rc=$?
    if [[ -z "$detail" ]]; then
        printf 'exit=%s <no grade output>\n' "$rc"
        return 0
    fi
    printf '%s\n' "$detail" | native_codegen_join_lines
    printf '\n'
}
