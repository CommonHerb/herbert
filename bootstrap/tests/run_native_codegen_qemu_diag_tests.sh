#!/usr/bin/env bash
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
helper="$script_dir/native_codegen_qemu_diag.sh"

if [[ ! -f "$helper" ]]; then
    echo "FAIL: native-codegen qemu diagnostics (missing helper: $helper)"
    exit 1
fi

source "$helper"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0
check_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" != "$want" ]]; then
        echo "FAIL: $label: got '$got' want '$want'"
        fail=$((fail + 1))
    fi
}

check_eq "debug-exit rc 245 low7" "$(native_codegen_qemu_exit_low7_hex 245)" "0x4b"
check_eq "debug-exit rc 233 low7" "$(native_codegen_qemu_exit_low7_hex 233)" "0x45"
check_eq "debug-exit timeout has no low7" "$(native_codegen_qemu_exit_low7_hex 124)" "n/a"

printf '\xde\x4b\xad' >"$tmp/e9.bin"
check_eq "e9 hex sample" "$(native_codegen_e9_hex "$tmp/e9.bin")" "de4bad"
check_eq "missing e9 hex sample" "$(native_codegen_e9_hex "$tmp/missing.bin")" "<missing>"

cat >"$tmp/ref.py" <<'PY'
#!/usr/bin/env python3
import sys
cmd = sys.argv[1]
if cmd != "grade":
    raise SystemExit(2)
if open(sys.argv[2], "rb").read() == b"ok":
    print("GREEN")
    raise SystemExit(0)
print("RED")
print("  - answer 0x4b != expected")
raise SystemExit(1)
PY
chmod +x "$tmp/ref.py"

printf 'bad' >"$tmp/bad.bin"
printf 'ok' >"$tmp/ok.bin"
check_eq "grade red detail" \
    "$(native_codegen_grade_detail "$tmp/ref.py" "$tmp/bad.bin" 10a043 c5 echo)" \
    "RED |   - answer 0x4b != expected"
check_eq "grade green detail" \
    "$(native_codegen_grade_detail "$tmp/ref.py" "$tmp/ok.bin" 10a043 c5 echo)" \
    "GREEN"

if [[ "$fail" -ne 0 ]]; then
    exit 1
fi

echo "PASS: native-codegen qemu diagnostics"
