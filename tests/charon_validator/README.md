# Charon toolchain validator

Compares two Charon-integration strategies head-to-head.

## Gates (all must pass)

- **build** — `bazel build @charon_toolchain//:charon_bin` succeeds.
- **smoke** — the built binary emits the expected version string (`0.1.181` by default).
- **hermetic** — the build log contains ≤2 references to ambient host tools (`rustup`, `~/.cargo/`, `/nix/store/`, `/Users/*/`, `/home/*/`). Nix-based tracks will always show some `/nix/store/` refs; two is the budget before we call the track leaky.
- **reproducible** — two cold builds (`bazel clean --expunge` between them) produce identical `charon` binary SHA-256.

## Ranking (among tracks passing all gates)

1. Cold build time (lower is better)
2. Ambient-tool reference count (lower is better)
3. External repo cache size (lower is better)

## Usage

```bash
tests/charon_validator/run.sh <track-a-worktree> <track-b-worktree> [report.md]
```

Exit codes:

| code | meaning |
|---|---|
| 0 | both tracks pass all gates (winner by rank) |
| 1 | exactly one track passes all gates |
| 2 | both tracks failed at least one gate |
| 3 | usage error |

## What it does *not* measure

- **Cross-platform reach** — run on each CI platform separately and diff reports.
- **Upgrade friction (LoC delta)** — manual code review.
- **Security posture of transitive deps** — separate concern.

## Overriding the expected version

```bash
CHARON_EXPECTED_VERSION=0.1.182 tests/charon_validator/run.sh ...
```
