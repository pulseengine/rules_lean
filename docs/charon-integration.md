# Charon integration (Track A — pure Bazel)

[Charon](https://github.com/AeneasVerif/charon) is the Rust → LLBC translator
used by the [Aeneas](https://github.com/AeneasVerif/aeneas) verification
pipeline. `rules_lean` bundles Charon so downstream Rust-to-Lean proofs can be
built entirely through Bazel, without rustup, Nix, or any host-provided
Rust toolchain.

## What gets downloaded

For each `charon_toolchain` tag, the extension fetches:

1. The Charon release tarball from
   `github.com/AeneasVerif/charon/releases` — two binaries `charon` and
   `charon-driver`.
2. A matching nightly Rust sysroot from `static.rust-lang.org/dist` — the
   `rustc`, `rust-std`, `rustc-dev`, and `rust-src` components for the host
   triple. `rustc-dev` is mandatory because `charon-driver` links against
   `librustc_driver`, which lives in that component rather than in `rustc`.

Every download is SHA-256-pinned via the `_KNOWN_CHARON_VERSIONS` registry in
`aeneas/extensions.bzl`; to add a new release, see the comment block at the top
of that dict.

## Enabling Charon in a module

```starlark
aeneas = use_extension("@rules_lean//aeneas:extensions.bzl", "aeneas")
aeneas.charon_toolchain(
    version = "build-2026.04.22.081730-2d35584fb79ef804c50f106d8c40bd3728284f8d",
)
use_repo(
    aeneas,
    "charon_toolchains",
    "charon_macos_aarch64",
    "charon_macos_x86_64",
    "charon_linux_x86_64",
    "charon_linux_aarch64",
)
register_toolchains("@charon_toolchains//:all")
```

## Platform support

| Platform        | Status | Notes                                                        |
|-----------------|:------:|--------------------------------------------------------------|
| macOS aarch64   |  OK    | Requires ~180 MB of sysroot                                  |
| macOS x86_64    |  OK    | Requires ~200 MB of sysroot                                  |
| Linux x86_64    |  OK    | Requires GLIBC_2.39+ (Ubuntu 24.04+)                         |
| Linux aarch64   | *not supported* | See below                                            |

### Linux aarch64 (known limitation)

Upstream Charon does not publish a `linux-aarch64` tarball. The
`charon_linux_aarch64` repository is still materialised (so `bazel query`
works on mixed-architecture monorepos), but its `charon` target is a stub
script that exits non-zero with a pointer to this document.

Workarounds:

* Build Charon from source yourself and point at it via a
  `local_repository` / `local_path_override`.
* Use the Nix-based Track B integration (see `.claude/worktrees/agent-*` or
  the parallel `rules_lean_nix` overlay), which compiles Charon through Nix
  and therefore works anywhere Nix does.
* Cross-compile from a Linux x86_64 CI host.

### Runtime env vars for downstream rules

`charon-driver` invokes `rustc` internally. The outer `charon` binary was
built under Nix, so it reads `CHARON_TOOLCHAIN_IS_IN_PATH=1` and expects
`rustc` to be discoverable via `PATH` rather than asking `rustup`. Rules that
actually run Charon (e.g. a future `charon_llbc` build rule) therefore need
to set:

```
CHARON_TOOLCHAIN_IS_IN_PATH=1
PATH=<rust_bin_path>:$PATH
DYLD_LIBRARY_PATH=<rust_lib_path>   # macOS — librustc_driver-*.dylib
LD_LIBRARY_PATH=<rust_lib_path>     # Linux — librustc_driver-*.so
```

The `charon_toolchain_info` provider exposes `rust_bin_path`, `rust_lib_path`,
and `rust_channel` for exactly this purpose. The `charon version` smoke test
does not need any of this — the outer `charon` binary is self-contained.

## Smoke test

```
bazel test //tests/charon_smoke:charon_version_smoke
```

Expected: `PASS: charon 0.1.181 smoke test`. The test scrubs `PATH` and
`HOME`, so any attempt by Charon to call `rustup` would fail and be caught.
