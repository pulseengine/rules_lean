# rules_lean

Bazel rules for building and verifying [Lean 4](https://lean-lang.org/) libraries and proofs,
with optional [Mathlib](https://github.com/leanprover-community/mathlib4) support.

## Quick Start

Add to your `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_lean", version = "0.1.0")

lean = use_extension("@rules_lean//lean:extensions.bzl", "lean")
lean.toolchain(version = "4.27.0")

use_repo(lean, "lean_toolchains")
register_toolchains("@lean_toolchains//:all")
```

### With Mathlib

```starlark
lean = use_extension("@rules_lean//lean:extensions.bzl", "lean")
lean.toolchain(version = "4.27.0")
lean.mathlib(rev = "v4.27.0")

use_repo(lean, "lean_toolchains", "mathlib")
register_toolchains("@lean_toolchains//:all")
```

## Usage

```starlark
load("@rules_lean//lean:defs.bzl", "lean_library", "lean_proof_test")

# Compile Lean sources and produce .olean files for downstream deps
lean_library(
    name = "my_lib",
    srcs = [
        "MyLib/Basic.lean",
        "MyLib/Defs.lean",
    ],
)

# Write proofs that depend on your library and/or Mathlib
lean_library(
    name = "my_proofs",
    srcs = ["Proofs/Correctness.lean"],
    deps = [
        ":my_lib",
        "@mathlib//:Mathlib",
    ],
)

# Verify proofs type-check (test target)
lean_proof_test(
    name = "my_proofs_test",
    srcs = ["Proofs/Correctness.lean"],
    deps = [
        ":my_lib",
        "@mathlib//:Mathlib",
    ],
)
```

## Rules

### `lean_library`

Compiles Lean 4 `.lean` source files and produces `.olean` outputs.

| Attribute     | Type          | Default | Description |
|---------------|---------------|---------|-------------|
| `srcs`        | label_list    | required | `.lean` source files, listed in compilation order |
| `deps`        | label_list    | `[]`     | `lean_library` or `lean_prebuilt_library` targets |
| `extra_flags` | string_list   | `[]`     | Additional flags passed to `lean` |

### `lean_proof_test`

Test rule that verifies `.lean` proofs type-check (proofs are valid).
Verification happens at build time; the test reports success.

| Attribute     | Type          | Default | Description |
|---------------|---------------|---------|-------------|
| `srcs`        | label_list    | required | `.lean` source files to verify |
| `deps`        | label_list    | `[]`     | `lean_library` or `lean_prebuilt_library` targets |
| `extra_flags` | string_list   | `[]`     | Additional flags passed to `lean` |

### `lean_prebuilt_library`

Wraps pre-built `.olean` files (e.g. Mathlib) as a Lean dependency.

| Attribute      | Type       | Default | Description |
|----------------|------------|---------|-------------|
| `srcs`         | label_list | required | Pre-built `.olean` and related files |
| `path_marker`  | label      | `None`   | Marker file at the root of the `.olean` directory tree |

## Toolchain Configuration

### SHA-256 Verification

For reproducible builds, provide SHA-256 hashes per platform:

```starlark
lean.toolchain(
    version = "4.27.0",
    sha256 = {
        "darwin_aarch64": "abc123...",
        "darwin_x86_64": "def456...",
        "linux_x86_64": "789abc...",
        "linux_aarch64": "012def...",
    },
)
```

Hashes can be obtained from the [Lean 4 releases page](https://github.com/leanprover/lean4/releases).

## Supported Platforms

| Platform            | Lean Artifact             |
|---------------------|---------------------------|
| macOS (Apple Silicon) | `darwin_aarch64`         |
| macOS (Intel)        | `darwin_x86_64`          |
| Linux (x86_64)      | `linux_x86_64`            |
| Linux (aarch64)     | `linux_aarch64`           |

## How It Works

1. **Toolchain download**: `lean_release` downloads pre-built Lean 4 binaries from
   GitHub releases for each supported platform.
2. **Toolchain resolution**: Bazel's toolchain system selects the correct platform
   binary at build time.
3. **Compilation**: `lean_library` compiles `.lean` files to `.olean` using the
   downloaded `lean` binary, with `LEAN_PATH` set to resolve imports from the
   standard library, Mathlib, and other dependencies.
4. **Mathlib**: `mathlib_repo` uses `lake` to fetch Mathlib and download pre-built
   oleans, consolidating them into a single directory for import resolution.

## License

Apache-2.0
