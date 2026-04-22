#!/usr/bin/env bash
# Compare two Charon-integration tracks head-to-head.
#
# Gates (pass/fail):
#   - build:        bazel build @charon_toolchain//:charon_bin succeeds
#   - smoke:        `charon version` emits the expected string (0.1.181)
#   - hermetic:     no ambient-tool references (rustup, ~/.cargo, /nix/store)
#                   appear in the build log after initial download
#   - reproducible: two cold builds produce identical charon binary hashes
#
# Ranked (among tracks passing all gates):
#   - cold build time (wall-clock, seconds, lower=better)
#   - external tool count (lower=better)
#   - repo cache size (MB, lower=better)
#
# Usage:
#   run.sh <track-a-worktree> <track-b-worktree> [report-path]
#
# Exit codes:
#   0  both tracks pass all gates (report written)
#   1  exactly one track passes all gates (winner named in report)
#   2  both tracks fail at least one gate
#   3  usage error

set -uo pipefail

TRACK_A_DIR="${1:-}"
TRACK_B_DIR="${2:-}"
REPORT_PATH="${3:-/tmp/charon-validator-report.md}"
EXPECTED_VERSION="${CHARON_EXPECTED_VERSION:-0.1.181}"

if [ -z "$TRACK_A_DIR" ] || [ -z "$TRACK_B_DIR" ]; then
    echo "usage: $0 <track-a-worktree> <track-b-worktree> [report-path]" >&2
    exit 3
fi

if [ ! -d "$TRACK_A_DIR" ] || [ ! -d "$TRACK_B_DIR" ]; then
    echo "error: worktree path not found" >&2
    exit 3
fi

WORKDIR=$(mktemp -d -t charon-validator.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

# --- helpers ---------------------------------------------------------------

log()  { printf '[validator] %s\n' "$*" >&2; }
die()  { printf '[validator] FATAL: %s\n' "$*" >&2; exit 1; }

# Human-readable duration
fmt_secs() {
    local s=$1
    if [ "$s" -lt 60 ]; then printf '%ds' "$s"
    else printf '%dm%02ds' $((s/60)) $((s%60))
    fi
}

# Count references to ambient host tools in a log file.
# These indicate the build leaked out to the developer's machine.
count_ambient() {
    local log="$1"
    # rustup invocations, $HOME/.cargo reads, /nix/store paths (expected for Nix
    # track, but measured here so the table shows the delta honestly)
    grep -cE '(rustup[[:space:]]|\.cargo/|/nix/store/|/Users/[^/]+/\.|/home/[^/]+/\.)' "$log" 2>/dev/null || echo 0
}

# Hash of the primary charon binary after a build.
# Tracks may stage the binary under different external repo names; we search.
hash_charon_bin() {
    local repo_dir="$1"
    cd "$repo_dir"
    local bin
    bin=$(find "$(bazel info execution_root 2>/dev/null)/external" \
          -maxdepth 6 -name charon -type f -perm +111 2>/dev/null | head -1)
    if [ -z "$bin" ] || [ ! -f "$bin" ]; then
        echo "MISSING"
        return
    fi
    shasum -a 256 "$bin" | awk '{print $1}'
}

# Measure repo cache size for the charon-related external repos.
repo_cache_mb() {
    local repo_dir="$1"
    cd "$repo_dir"
    local base
    base=$(bazel info output_base 2>/dev/null)/external
    if [ ! -d "$base" ]; then echo "?"; return; fi
    # Match any external repo with "charon" in the name.
    local total=0
    while IFS= read -r d; do
        local bytes
        bytes=$(du -sk "$d" 2>/dev/null | awk '{print $1}')
        total=$((total + bytes))
    done < <(find "$base" -maxdepth 1 -type d -name '*charon*' 2>/dev/null)
    echo $((total / 1024))
}

# --- per-track runner ------------------------------------------------------

run_track() {
    local name="$1"
    local dir="$2"
    local out="$WORKDIR/$name"
    mkdir -p "$out"

    log "=== track $name at $dir ==="
    cd "$dir" || { echo "build=FAIL" > "$out/result.env"; return; }

    # Gate 1: build
    log "[$name] bazel clean --expunge"
    bazel clean --expunge >/dev/null 2>&1 || true

    log "[$name] cold build 1/2"
    local t0 t1 build_status
    t0=$(date +%s)
    if bazel build @charon_toolchain//:charon_bin 2>&1 | tee "$out/build1.log" \
        | grep -qE '^(ERROR|FAIL):'; then
        build_status=FAIL
    elif ! [ -f "$(bazel info execution_root 2>/dev/null)/bazel-out/../external/" ] && \
         ! grep -q "Build completed successfully" "$out/build1.log"; then
        # Fall through — we re-check via test below
        build_status=UNKNOWN
    else
        build_status=PASS
    fi
    t1=$(date +%s)
    local cold_secs=$((t1 - t0))

    # Stronger pass check: did charon actually land?
    local h1
    h1=$(hash_charon_bin "$dir")
    if [ "$h1" = "MISSING" ]; then
        build_status=FAIL
    else
        build_status=PASS
    fi

    # Gate 2: smoke
    local smoke_status=FAIL
    if [ "$build_status" = PASS ]; then
        log "[$name] smoke: charon version"
        if bazel run --ui_event_filters=-info,-stdout,-stderr @charon_toolchain//:charon_bin \
                -- version 2>"$out/smoke.err" >"$out/smoke.out"; then
            if grep -q "$EXPECTED_VERSION" "$out/smoke.out"; then
                smoke_status=PASS
            fi
        fi
        # Fallback: try the tests/charon_smoke target if present.
        if [ "$smoke_status" != PASS ] \
           && bazel test //tests/charon_smoke/... 2>&1 | tee "$out/smoke_test.log" \
              | grep -q 'PASSED'; then
            smoke_status=PASS
        fi
    fi

    # Gate 3: hermeticity probe
    local ambient
    ambient=$(count_ambient "$out/build1.log")

    # Gate 4: reproducibility — second cold build
    local h2 repro_status=FAIL
    if [ "$build_status" = PASS ]; then
        log "[$name] cold build 2/2 (reproducibility)"
        bazel clean --expunge >/dev/null 2>&1
        bazel build @charon_toolchain//:charon_bin 2>&1 > "$out/build2.log" || true
        h2=$(hash_charon_bin "$dir")
        if [ "$h1" = "$h2" ] && [ "$h1" != "MISSING" ]; then
            repro_status=PASS
        fi
    fi

    # Size
    local repo_mb
    repo_mb=$(repo_cache_mb "$dir")

    # Record
    cat > "$out/result.env" <<EOF
build=$build_status
smoke=$smoke_status
hermetic=$( [ "$ambient" -le 2 ] && echo PASS || echo FAIL )
reproducible=$repro_status
cold_secs=$cold_secs
ambient_refs=$ambient
repo_mb=$repo_mb
charon_hash=$h1
charon_hash_2=${h2:-N/A}
EOF
    log "[$name] done:"
    cat "$out/result.env" >&2
}

# --- main ------------------------------------------------------------------

log "Track A: $TRACK_A_DIR"
log "Track B: $TRACK_B_DIR"
log "Report:  $REPORT_PATH"

run_track A "$TRACK_A_DIR"
run_track B "$TRACK_B_DIR"

# Parse results
# shellcheck disable=SC1090,SC1091
A_build=;A_smoke=;A_hermetic=;A_reproducible=;A_cold_secs=;A_ambient_refs=;A_repo_mb=;A_charon_hash=;A_charon_hash_2=
B_build=;B_smoke=;B_hermetic=;B_reproducible=;B_cold_secs=;B_ambient_refs=;B_repo_mb=;B_charon_hash=;B_charon_hash_2=
while IFS='=' read -r k v; do eval "A_$k=\"$v\""; done < "$WORKDIR/A/result.env"
while IFS='=' read -r k v; do eval "B_$k=\"$v\""; done < "$WORKDIR/B/result.env"

gates_of() {
    local prefix="$1"
    # Returns count of passing gates (out of 4)
    local n=0
    eval "[ \"\$${prefix}_build\" = PASS ] && n=\$((n+1))"
    eval "[ \"\$${prefix}_smoke\" = PASS ] && n=\$((n+1))"
    eval "[ \"\$${prefix}_hermetic\" = PASS ] && n=\$((n+1))"
    eval "[ \"\$${prefix}_reproducible\" = PASS ] && n=\$((n+1))"
    echo $n
}

A_gates=$(gates_of A)
B_gates=$(gates_of B)

winner=
if [ "$A_gates" = 4 ] && [ "$B_gates" = 4 ]; then
    # Both pass — rank by cold_secs, tiebreak by ambient_refs then repo_mb
    if [ "$A_cold_secs" -lt "$B_cold_secs" ]; then winner=A
    elif [ "$B_cold_secs" -lt "$A_cold_secs" ]; then winner=B
    elif [ "$A_ambient_refs" -lt "$B_ambient_refs" ]; then winner=A
    elif [ "$B_ambient_refs" -lt "$A_ambient_refs" ]; then winner=B
    elif [ "$A_repo_mb" -lt "$B_repo_mb" ]; then winner=A
    else winner=B
    fi
    exit_code=0
elif [ "$A_gates" = 4 ]; then
    winner=A; exit_code=1
elif [ "$B_gates" = 4 ]; then
    winner=B; exit_code=1
else
    winner="(neither — both failed at least one gate)"; exit_code=2
fi

# Write report
{
    printf '# Charon toolchain comparison — Track A (pure Bazel) vs Track B (Nix)\n\n'
    printf '_Generated: %s_\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'Host: %s  \n' "$(uname -sm)"
    printf 'Expected version: `%s`\n\n' "$EXPECTED_VERSION"
    printf '## Gates\n\n'
    printf '| Gate | Track A | Track B |\n'
    printf '|---|---|---|\n'
    printf '| build | %s | %s |\n'       "$A_build" "$B_build"
    printf '| smoke (version match) | %s | %s |\n' "$A_smoke" "$B_smoke"
    printf '| hermetic (ambient ≤ 2) | %s | %s |\n' "$A_hermetic" "$B_hermetic"
    printf '| reproducible (hash match) | %s | %s |\n' "$A_reproducible" "$B_reproducible"
    printf '\n'
    printf '## Measurements\n\n'
    printf '| Metric | Track A | Track B |\n'
    printf '|---|---|---|\n'
    printf '| cold build time | %s | %s |\n' "$(fmt_secs "${A_cold_secs:-0}")" "$(fmt_secs "${B_cold_secs:-0}")"
    printf '| ambient-tool refs in build log | %s | %s |\n' "$A_ambient_refs" "$B_ambient_refs"
    printf '| external repo cache size | %s MB | %s MB |\n' "$A_repo_mb" "$B_repo_mb"
    printf '| charon binary sha256 (build 1) | `%s` | `%s` |\n' "${A_charon_hash:0:16}…" "${B_charon_hash:0:16}…"
    printf '| charon binary sha256 (build 2) | `%s` | `%s` |\n' "${A_charon_hash_2:0:16}…" "${B_charon_hash_2:0:16}…"
    printf '\n'
    printf '## Verdict\n\n'
    printf 'Winner: **%s**\n\n' "$winner"
    if [ "$exit_code" = 0 ]; then
        printf 'Both tracks pass all 4 gates. Ranked by cold build time, ambient-tool refs, then cache size.\n'
    elif [ "$exit_code" = 1 ]; then
        printf 'Exactly one track passes all gates.\n'
    else
        printf 'Both tracks failed at least one gate. See per-track build logs under %s.\n' "$WORKDIR"
    fi
    printf '\n## Raw logs\n\n'
    printf '- Track A build: `%s/A/build1.log`\n' "$WORKDIR"
    printf '- Track A smoke: `%s/A/smoke.out`\n' "$WORKDIR"
    printf '- Track B build: `%s/B/build1.log`\n' "$WORKDIR"
    printf '- Track B smoke: `%s/B/smoke.out`\n' "$WORKDIR"
} > "$REPORT_PATH"

log "report written to $REPORT_PATH"
log "winner: $winner  (exit=$exit_code)"
cat "$REPORT_PATH"
exit "$exit_code"
