#!/usr/bin/env bash
# Shared Role-1 oracle for the native-codegen tests.
#
# Default mode validates live-C-derived native-canonical artifacts against the
# committed golden. Golden mode loads only the committed artifact.

native_codegen_oracle__script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_CODEGEN_GOLDENS_DIR="${NATIVE_CODEGEN_GOLDENS_DIR:-$native_codegen_oracle__script_dir/native_codegen_goldens}"
NATIVE_CODEGEN_ORACLE="${NATIVE_CODEGEN_ORACLE:-c}"
NATIVE_CODEGEN_CAPTURE="${NATIVE_CODEGEN_ORACLE_CAPTURE:-0}"
NATIVE_CODEGEN_MANIFEST="${NATIVE_CODEGEN_MANIFEST:-$NATIVE_CODEGEN_GOLDENS_DIR/manifest.tsv}"
NATIVE_CODEGEN_CAPTURE_MANIFEST="${NATIVE_CODEGEN_CAPTURE_MANIFEST:-$NATIVE_CODEGEN_MANIFEST}"

native_codegen_oracle_script=
native_codegen_oracle_consumed=

native_codegen_oracle_fail() {
    echo "FAIL: native-codegen oracle ($1)" >&2
    return 1
}

native_codegen_oracle_begin() {
    native_codegen_oracle_script="$1"
    native_codegen_oracle_consumed="$(mktemp)"
    case "$NATIVE_CODEGEN_ORACLE" in
        ""|c|golden) ;;
        *) native_codegen_oracle_fail "unknown NATIVE_CODEGEN_ORACLE=$NATIVE_CODEGEN_ORACLE"; return 1 ;;
    esac
    if [[ "$NATIVE_CODEGEN_CAPTURE" == "1" ]]; then
        mkdir -p "$NATIVE_CODEGEN_GOLDENS_DIR/artifacts/$native_codegen_oracle_script"
        if [[ ! -f "$NATIVE_CODEGEN_CAPTURE_MANIFEST" ]]; then
            printf 'case_id\tscript\tprobe_label\tinput_label\tkind\texpected\tprobe_sha256\tinput_sha256\tc_transform\n' >"$NATIVE_CODEGEN_CAPTURE_MANIFEST"
        fi
    elif [[ ! -f "$NATIVE_CODEGEN_MANIFEST" ]]; then
        native_codegen_oracle_fail "missing manifest $NATIVE_CODEGEN_MANIFEST; run bootstrap/tests/capture_native_goldens.sh"
        return 1
    fi
}

native_codegen_oracle_case_id() {
    local path="$1"
    local base
    base="$(basename "$path")"
    base="${base%.bin}"
    base="${base%.expected}"
    base="${base%.actual}"
    printf '%s_%s' "$native_codegen_oracle_script" "$base" | tr -cs 'A-Za-z0-9_' '_'
}

native_codegen_oracle_sha256() {
    sha256sum "$1" | awk '{print $1}'
}

native_codegen_oracle_manifest_row() {
    local case_id="$1"
    awk -F '\t' -v cid="$case_id" -v script="$native_codegen_oracle_script" '
        NR == 1 { next }
        $1 == cid && $2 == script { print; found++ }
        END { if (found != 1) exit found == 0 ? 2 : 3 }
    ' "$NATIVE_CODEGEN_MANIFEST"
}

native_codegen_oracle_consume() {
    local case_id="$1"
    if grep -Fxq "$case_id" "$native_codegen_oracle_consumed"; then
        native_codegen_oracle_fail "$case_id consumed more than once"
        return 1
    fi
    printf '%s\n' "$case_id" >>"$native_codegen_oracle_consumed"
}

native_codegen_oracle_finish() {
    [[ "$NATIVE_CODEGEN_CAPTURE" == "1" ]] && return 0
    local missing=0
    while IFS=$'\t' read -r case_id script _rest; do
        [[ "$case_id" == "case_id" ]] && continue
        [[ "$script" == "$native_codegen_oracle_script" ]] || continue
        if ! grep -Fxq "$case_id" "$native_codegen_oracle_consumed"; then
            echo "FAIL: native-codegen oracle (manifest row not consumed: $native_codegen_oracle_script/$case_id)" >&2
            missing=1
        fi
    done <"$NATIVE_CODEGEN_MANIFEST"
    rm -f "$native_codegen_oracle_consumed"
    [[ $missing -eq 0 ]]
}

native_codegen_compiler_mint() {
    local mint_root="$1"
    local mint_work="$mint_root/work"
    local compiler="$mint_root/gen1-herbert"
    local out="$mint_root/mint.out"
    local err="$mint_root/mint.err"
    local timeout_arg="${NATIVE_SELF_TIMEOUT:-480s}"
    local start end elapsed rc magic count

    if [[ -z "${HERBERT:-}" || ! -x "$HERBERT" ]]; then
        echo "FAIL: stack/native_compile_fragment.herb (cannot find herbert at ${HERBERT:-<unset>})"
        return 1
    fi
    if [[ -z "${backend:-}" || ! -f "$backend" ]]; then
        echo "FAIL: stack/native_compile_fragment.herb (missing backend ${backend:-<unset>})"
        return 1
    fi

    rm -rf "$mint_root"
    mkdir -p "$mint_work" || return 1

    start=$(date +%s)
    if command -v timeout >/dev/null 2>&1; then
        ( cd "$mint_work" && timeout "$timeout_arg" "$HERBERT" "$backend" <"$backend" >"$out" 2>"$err" )
        rc=$?
    else
        ( cd "$mint_work" && "$HERBERT" "$backend" <"$backend" >"$out" 2>"$err" )
        rc=$?
    fi
    end=$(date +%s)
    elapsed=$((end - start))

    magic=""
    [[ -f "$mint_work/a.out" ]] && magic=$(head -c4 "$mint_work/a.out" | xxd -p | tr -d '\n')
    if [[ $rc -ne 0 || "$magic" != "7f454c46" ]]; then
        echo "FAIL: stack/native_compile_fragment.herb (gen-1 mint failed: rc=$rc magic=$magic stdout=$(head -1 "$out" 2>/dev/null) stderr=$(head -1 "$err" 2>/dev/null))"
        return 1
    fi

    cp "$mint_work/a.out" "$compiler" || return 1
    chmod +x "$compiler" || return 1
    export NATIVE_CODEGEN_COMPILER="$compiler"
    export NATIVE_CODEGEN_COMPILER_MINT_SECONDS="$elapsed"

    count="${NATIVE_CODEGEN_COMPILER_MINT_COUNT:-0}"
    case "$count" in
        ''|*[!0-9]*) count=0 ;;
    esac
    count=$((count + 1))
    export NATIVE_CODEGEN_COMPILER_MINT_COUNT="$count"
    echo "native-codegen: minted gen-1 compiler at $NATIVE_CODEGEN_COMPILER (mint-count=$count, seconds=$elapsed)"
}

native_codegen_ensure_compiler() {
    local mint_root="$1"
    if [[ -n "${NATIVE_CODEGEN_COMPILER:-}" ]]; then
        if [[ ! -x "$NATIVE_CODEGEN_COMPILER" ]]; then
            echo "FAIL: stack/native_compile_fragment.herb (cannot execute NATIVE_CODEGEN_COMPILER=$NATIVE_CODEGEN_COMPILER)"
            return 1
        fi
        return 0
    fi
    native_codegen_compiler_mint "$mint_root"
}

native_codegen_oracle_append_manifest() {
    local case_id="$1" probe="$2" input="$3" kind="$4" expected_rel="$5" transform="$6"
    local probe_label input_label probe_hash input_hash
    probe_label="$(basename "$probe")"
    input_label="$(basename "$input")"
    probe_hash="$(native_codegen_oracle_sha256 "$probe")"
    input_hash="$(native_codegen_oracle_sha256 "$input")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$case_id" "$native_codegen_oracle_script" "$probe_label" "$input_label" \
        "$kind" "$expected_rel" "$probe_hash" "$input_hash" "$transform" \
        >>"$NATIVE_CODEGEN_CAPTURE_MANIFEST"
}

native_codegen_oracle_prepare_expected() {
    local case_id="$1" probe="$2" input="$3" out="$4" transform="$5" derived="$6" derived_kind="$7"
    local row script probe_label input_label row_kind expected_rel probe_hash input_hash row_transform
    local expected_abs current_probe_hash current_input_hash

    native_codegen_oracle_consume "$case_id" || return 1

    if [[ "$NATIVE_CODEGEN_CAPTURE" == "1" ]]; then
        expected_rel="artifacts/$native_codegen_oracle_script/$case_id.bin"
        expected_abs="$NATIVE_CODEGEN_GOLDENS_DIR/$expected_rel"
        mkdir -p "$(dirname "$expected_abs")"
        cp "$derived" "$expected_abs"
        native_codegen_oracle_append_manifest "$case_id" "$probe" "$input" "$derived_kind" "$expected_rel" "$transform"
        cp "$expected_abs" "$out"
        printf '%s\n' "$derived_kind"
        return 0
    fi

    row="$(native_codegen_oracle_manifest_row "$case_id")"
    local lookup_rc=$?
    if [[ $lookup_rc -eq 2 ]]; then
        native_codegen_oracle_fail "missing manifest row for $native_codegen_oracle_script/$case_id"
        return 1
    elif [[ $lookup_rc -eq 3 ]]; then
        native_codegen_oracle_fail "duplicate manifest rows for $native_codegen_oracle_script/$case_id"
        return 1
    elif [[ $lookup_rc -ne 0 ]]; then
        native_codegen_oracle_fail "manifest lookup failed for $native_codegen_oracle_script/$case_id"
        return 1
    fi

    IFS=$'\t' read -r _case_id script probe_label input_label row_kind expected_rel probe_hash input_hash row_transform <<<"$row"
    expected_abs="$NATIVE_CODEGEN_GOLDENS_DIR/$expected_rel"
    if [[ ! -f "$expected_abs" ]]; then
        native_codegen_oracle_fail "missing golden artifact $expected_rel for $case_id"
        return 1
    fi
    current_probe_hash="$(native_codegen_oracle_sha256 "$probe")"
    current_input_hash="$(native_codegen_oracle_sha256 "$input")"
    if [[ "$current_probe_hash" != "$probe_hash" ]]; then
        native_codegen_oracle_fail "$case_id probe hash drift: $current_probe_hash != $probe_hash"
        return 1
    fi
    if [[ "$current_input_hash" != "$input_hash" ]]; then
        native_codegen_oracle_fail "$case_id input hash drift: $current_input_hash != $input_hash"
        return 1
    fi

    if [[ "$NATIVE_CODEGEN_ORACLE" == "golden" ]]; then
        cp "$expected_abs" "$out"
        printf '%s\n' "$row_kind"
        return 0
    fi

    if [[ "$row_kind" != "$derived_kind" ]]; then
        native_codegen_oracle_fail "$case_id kind drift: C produced $derived_kind, golden records $row_kind"
        return 1
    fi
    if [[ "$row_transform" != "$transform" ]]; then
        native_codegen_oracle_fail "$case_id transform drift: $row_transform != $transform"
        return 1
    fi
    if ! cmp -s "$derived" "$expected_abs"; then
        native_codegen_oracle_fail "$case_id C-derived artifact differs from committed golden (golden=$(xxd -p "$expected_abs" | tr -d '\n') C=$(xxd -p "$derived" | tr -d '\n'))"
        return 1
    fi
    cp "$expected_abs" "$out"
    printf '%s\n' "$row_kind"
}

native_codegen_oracle_pack_stdio_exit() {
    local exit_status="$1" stdout_file="$2" stderr_file="$3" out="$4"
    python3 - "$exit_status" "$stdout_file" "$stderr_file" "$out" <<'PY'
import struct
import sys

exit_status = int(sys.argv[1]) & 0xFFFFFFFFFFFFFFFF
with open(sys.argv[2], "rb") as f:
    stdout = f.read()
with open(sys.argv[3], "rb") as f:
    stderr = f.read()
with open(sys.argv[4], "wb") as f:
    f.write(struct.pack("<Q", exit_status))
    f.write(struct.pack("<Q", len(stdout)))
    f.write(stdout)
    f.write(struct.pack("<Q", len(stderr)))
    f.write(stderr)
PY
}

oracle_expect_le64() {
    local case_id="$1" probe="$2" input="$3" out="$4"
    local derived
    derived="$(mktemp)"
    if [[ "$NATIVE_CODEGEN_CAPTURE" == "1" || "$NATIVE_CODEGEN_ORACLE" != "golden" ]]; then
        # D14: the native program renders its main return value as canonical text
        # (unsigned decimal / true|false) + newline directly to stdout, so the golden
        # is C's full canonical stdout. Captured to a file (not command substitution,
        # which strips the trailing newline). No LE64 packing. Kind tag stays "le64".
        if ! "$HERBERT" "$probe" <"$input" >"$derived" 2>/dev/null; then
            rm -f "$derived"
            return 1
        fi
    fi
    native_codegen_oracle_prepare_expected "$case_id" "$probe" "$input" "$out" "c_stdout_canonical" "$derived" "le64" >/dev/null
    local rc=$?
    rm -f "$derived"
    return $rc
}

oracle_expect_payload() {
    local case_id="$1" probe="$2" input="$3" out="$4"
    local derived c_out size trailer
    derived="$(mktemp)"
    c_out="$(mktemp)"
    if [[ "$NATIVE_CODEGEN_CAPTURE" == "1" || "$NATIVE_CODEGEN_ORACLE" != "golden" ]]; then
        if ! "$HERBERT" "$probe" <"$input" >"$c_out" 2>/dev/null; then
            rm -f "$derived" "$c_out"
            return 1
        fi
        size=$(wc -c <"$c_out")
        if (( size < 2 )); then
            rm -f "$derived" "$c_out"
            return 1
        fi
        trailer="$(tail -c2 "$c_out" | xxd -p | tr -d '\n')"
        if [[ "$trailer" != "300a" ]]; then
            native_codegen_oracle_fail "$case_id C payload trailer was $trailer, expected 300a"
            rm -f "$derived" "$c_out"
            return 1
        fi
        head -c $((size - 2)) "$c_out" >"$derived"
    fi
    native_codegen_oracle_prepare_expected "$case_id" "$probe" "$input" "$out" "c_stdout_strip_decimal_zero_trailer" "$derived" "payload" >/dev/null
    local rc=$?
    rm -f "$derived" "$c_out"
    return $rc
}

oracle_expect_trap_stdout() {
    local case_id="$1" probe="$2" input="$3" out="$4"
    local derived
    derived="$(mktemp)"
    if [[ "$NATIVE_CODEGEN_CAPTURE" == "1" || "$NATIVE_CODEGEN_ORACLE" != "golden" ]]; then
        "$HERBERT" "$probe" <"$input" >"$derived" 2>/dev/null
        local c_rc=$?
        if [[ $c_rc -eq 0 ]]; then
            rm -f "$derived"
            return 1
        fi
    fi
    native_codegen_oracle_prepare_expected "$case_id" "$probe" "$input" "$out" "c_trap_stdout" "$derived" "trap_stdout" >/dev/null
    local rc=$?
    rm -f "$derived"
    return $rc
}

oracle_expect_stdio_exit() {
    local case_id="$1" probe="$2" input="$3" out="$4"
    local derived c_out c_err c_rc
    derived="$(mktemp)"
    c_out="$(mktemp)"
    c_err="$(mktemp)"
    if [[ "$NATIVE_CODEGEN_CAPTURE" == "1" || "$NATIVE_CODEGEN_ORACLE" != "golden" ]]; then
        "$HERBERT" "$probe" <"$input" >"$c_out" 2>"$c_err"
        c_rc=$?
        native_codegen_oracle_pack_stdio_exit "$c_rc" "$c_out" "$c_err" "$derived" || {
            rm -f "$derived" "$c_out" "$c_err"
            return 1
        }
    fi
    native_codegen_oracle_prepare_expected "$case_id" "$probe" "$input" "$out" "c_stdio_exit_envelope" "$derived" "stdio_exit" >/dev/null
    local rc=$?
    rm -f "$derived" "$c_out" "$c_err"
    return $rc
}

oracle_expect_return_or_trap() {
    local case_id="$1" probe="$2" input="$3" out="$4" kind_out="$5"
    local derived c_out c_rc derived_kind row_kind
    derived="$(mktemp)"
    c_out="$(mktemp)"
    derived_kind="le64"
    if [[ "$NATIVE_CODEGEN_CAPTURE" == "1" || "$NATIVE_CODEGEN_ORACLE" != "golden" ]]; then
        "$HERBERT" "$probe" <"$input" >"$c_out" 2>/dev/null
        c_rc=$?
        if [[ $c_rc -eq 0 ]]; then
            # D14: success path stores C's full canonical stdout (value + newline),
            # matching the native program's own decimal/bool render. No LE64 packing.
            cp "$c_out" "$derived"
            derived_kind="le64"
        else
            cp "$c_out" "$derived"
            derived_kind="trap_stdout"
        fi
    fi
    row_kind="$(native_codegen_oracle_prepare_expected "$case_id" "$probe" "$input" "$out" "c_stdout_canonical_or_trap_stdout" "$derived" "$derived_kind")"
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        printf '%s\n' "$row_kind" >"$kind_out"
    fi
    rm -f "$derived" "$c_out"
    return $rc
}

oracle_expect_file() {
    local case_id="$1" probe="$2" run_dir="$3" artifact="$4" out="$5"
    local input="$6"
    local derived artifact_path
    derived="$(mktemp)"
    if [[ "$NATIVE_CODEGEN_CAPTURE" == "1" || "$NATIVE_CODEGEN_ORACLE" != "golden" ]]; then
        rm -rf "$run_dir"
        mkdir -p "$run_dir"
        ( cd "$run_dir" && "$HERBERT" "$probe" >/dev/null 2>&1 )
        artifact_path="$run_dir/$artifact"
        if [[ ! -f "$artifact_path" ]]; then
            rm -f "$derived"
            return 1
        fi
        cp "$artifact_path" "$derived"
    fi
    native_codegen_oracle_prepare_expected "$case_id" "$probe" "$input" "$out" "c_runtime_file_artifact" "$derived" "file" >/dev/null
    local rc=$?
    rm -f "$derived"
    return $rc
}
