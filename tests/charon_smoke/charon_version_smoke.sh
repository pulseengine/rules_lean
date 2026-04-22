#!/usr/bin/env bash
# Smoke test for the Charon toolchain downloaded by rules_lean.
#
# Requirements (per the AeneasVerif Charon Track A integration):
#   * `charon version` must print the expected version.
#   * No rustup invocation. No $HOME/.cargo reads. No network access.
#
# We pass the resolved rootpath of the charon binary as argv[1].

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <path-to-charon>" >&2
    exit 2
fi

CHARON="$1"

if [[ ! -x "$CHARON" ]]; then
    echo "ERROR: charon binary not found or not executable: $CHARON" >&2
    exit 1
fi

# Sanity — deny rustup leakage by scrubbing PATH and HOME.
# Keep /usr/bin + /bin so the kernel can run `sh` inside any child processes
# charon might spawn internally, but nothing under $HOME and no homebrew paths.
export PATH="/usr/bin:/bin"
export HOME="$(mktemp -d)"
unset RUSTUP_HOME CARGO_HOME RUSTUP_TOOLCHAIN CHARON_TOOLCHAIN_DIR || true
trap 'rm -rf "$HOME"' EXIT

EXPECTED="0.1.181"

# Capture both stdout and stderr. `charon version` should print the version on
# stdout and exit 0 without trying to invoke rustup.
OUTPUT="$("$CHARON" version 2>&1)"
RC=$?

echo "--- charon version output ---"
echo "$OUTPUT"
echo "-----------------------------"

if [[ $RC -ne 0 ]]; then
    echo "FAIL: charon version exited $RC" >&2
    exit 1
fi

if ! grep -qE "(^|[^0-9.])${EXPECTED//./\\.}([^0-9.]|$)" <<<"$OUTPUT"; then
    echo "FAIL: expected version '$EXPECTED' in output" >&2
    exit 1
fi

if grep -qi "rustup" <<<"$OUTPUT"; then
    echo "FAIL: output mentions rustup (suggests rustup was invoked)" >&2
    exit 1
fi

echo "PASS: charon $EXPECTED smoke test"
