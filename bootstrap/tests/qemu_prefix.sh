# Shared test-only emulator selection. Source this file with `|| exit 1`.
# Unset/empty QEMU_PREFIX preserves PATH; a specified prefix must resolve exactly.
# A regular executable may be an exec-style wrapper. A non-exec wrapper can hide
# signal termination; this path check cannot establish wrapper behavior.
if [[ -n "${QEMU_PREFIX:-}" ]]; then
    qp_bin="$QEMU_PREFIX/bin/qemu-system-x86_64"
    # -x alone is TRUE for a DIRECTORY and says nothing about the prefix being absolute, so a
    # prefix that passed it could still leave PATH lookup resolving to the system qemu 8.2.2 --
    # the exact silent downgrade this knob exists to retire (parent delta refutation panel,
    # 2026-09-02). Require a REGULAR executable file at an ABSOLUTE path: a relative prefix
    # installs a relative PATH entry that silently stops resolving after any `cd`.
    if [[ "$QEMU_PREFIX" != /* || ! -f "$qp_bin" || ! -x "$qp_bin" ]]; then
        echo "FAIL: QEMU_PREFIX='$QEMU_PREFIX' is set but $qp_bin is not an executable REGULAR FILE at an ABSOLUTE path -- refusing to fall back to a system qemu" >&2
        return 1
    fi
    # A shell FUNCTION shadows PATH lookup entirely, so an inherited `export -f qemu-system-x86_64`
    # silently restored the system 8.2.2 while this guard reported success (Codex refutation leg,
    # 2026-09-02). Drop any such shadow, then PROVE the resolution instead of assuming it: the knob's
    # promise is that the PINNED binary runs, and only `command -v` after the prepend establishes it.
    unset -f qemu-system-x86_64 2>/dev/null || true
    export PATH="$QEMU_PREFIX/bin:$PATH"
    qp_res="$(command -v qemu-system-x86_64 || true)"
    if [[ "$qp_res" != "$qp_bin" ]]; then
        echo "FAIL: QEMU_PREFIX='$QEMU_PREFIX' is set but qemu-system-x86_64 resolves to '${qp_res:-<nothing>}', not '$qp_bin' -- refusing to fall back to a system qemu" >&2
        return 1
    fi
fi

unset CDPATH
kernel_evidence_helper_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || return 1
source "$kernel_evidence_helper_dir/kernel_evidence.sh" || return 1
