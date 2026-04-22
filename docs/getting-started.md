---
title: Getting Started with rules_lean
---

# Getting Started

rules_lean provides Bazel rules for building and verifying Lean 4 proofs,
with optional Mathlib and Aeneas integration.

## Prerequisites

- Bazel 8.0.0+ (via [bazelisk](https://github.com/bazelbuild/bazelisk))
- Internet access (for toolchain download on first build)

## Quick Setup

Add to your `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_lean", version = "0.1.0")

lean = use_extension("@rules_lean//lean:extensions.bzl", "lean")
lean.toolchain(version = "4.29.1")

use_repo(lean, "lean_toolchains")
register_toolchains("@lean_toolchains//:all")
```

## Your First Lean Proof

Create `proofs/Hello.lean`:

```lean
theorem hello_world : 1 + 1 = 2 := by rfl

theorem nat_comm (a b : Nat) : a + b = b + a := by omega
```

Create `proofs/BUILD.bazel`:

```starlark
load("@rules_lean//lean:defs.bzl", "lean_library", "lean_proof_test")

lean_library(
    name = "hello",
    srcs = ["Hello.lean"],
)

lean_proof_test(
    name = "hello_test",
    srcs = ["Hello.lean"],
)
```

Build and test:

```bash
bazel build //proofs:hello      # Compile to .olean
bazel test //proofs:hello_test  # Verify proofs typecheck
```

## Adding Mathlib

To use Mathlib lemmas and tactics, add to `MODULE.bazel`:

```starlark
lean = use_extension("@rules_lean//lean:extensions.bzl", "lean")
lean.toolchain(version = "4.29.1")
lean.mathlib(rev = "v4.29.1")

use_repo(lean, "lean_toolchains", "mathlib")
register_toolchains("@lean_toolchains//:all")
```

Then depend on `@mathlib//:Mathlib` in your BUILD:

```starlark
lean_library(
    name = "my_proofs",
    srcs = ["MyProofs.lean"],
    deps = ["@mathlib//:Mathlib"],
)
```

The first build downloads ~7800 pre-built Mathlib oleans (~2-3 minutes).
Subsequent builds use Bazel's cache.

## Multi-File Libraries

List source files in dependency order (imported files first):

```starlark
lean_library(
    name = "my_lib",
    srcs = [
        "Defs.lean",    # No imports
        "Props.lean",   # import Defs
        "Main.lean",    # import Defs; import Props
    ],
)
```

## SHA-256 Verification

By default, all toolchain downloads require SHA-256 verification.
Known versions (4.27.0, 4.29.1) have hashes built in. Older pins remain
in the registry so downstream consumers can upgrade on their own cadence.
For development with unreleased versions, opt out explicitly:

```starlark
lean.toolchain(
    version = "4.30.0-rc2",
    require_hashes = False,  # Development only!
)
```

## Artifact Traceability

This project uses [rivet](https://github.com/pulseengine/rivet) for
SDLC artifact traceability. Artifacts are stored as YAML in `artifacts/`.

```bash
rivet validate     # Validate all artifacts
rivet list         # List all artifacts
rivet stats        # Show summary statistics
rivet coverage     # Show traceability coverage
```
