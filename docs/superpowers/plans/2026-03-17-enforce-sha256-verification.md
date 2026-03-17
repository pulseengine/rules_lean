# Enforce SHA-256 Hash Verification Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent tampered Lean binaries from being used by enforcing SHA-256 hash verification on all toolchain downloads, with an explicit opt-out for development.

**Architecture:** Add a `require_hashes` boolean to the toolchain tag (default `True`). When enabled, the extension `fail()`s if any platform hash resolves to empty. A `--define lean_dev_mode=true` escape hatch disables the check for local development with unreleased versions. CI tests verify both enforcement and the escape hatch.

**Tech Stack:** Starlark (Bazel), GitHub Actions CI, rivet CLI (artifact tracking)

**Traces:** SC-002, CC-002, UCA-002, H-002, L-003

---

## Chunk 1: Enforce hashes + dev-mode escape hatch

### Task 1: Add hash enforcement to the module extension

**Files:**
- Modify: `lean/extensions.bzl:31-65`

- [ ] **Step 1: Add `require_hashes` attr to toolchain tag**

Add a boolean attribute to `_LeanToolchainTag`:

```starlark
_LeanToolchainTag = tag_class(attrs = {
    "version": attr.string(mandatory = True, doc = "Lean 4 version (e.g. '4.27.0')"),
    "sha256": attr.string_dict(default = {}, doc = "Per-platform SHA-256 overrides (keys: darwin_aarch64, etc.)"),
    "require_hashes": attr.bool(default = True, doc = "Fail if any platform hash is empty. Set False for development with unreleased versions."),
})
```

- [ ] **Step 2: Add enforcement logic to `_lean_impl`**

After resolving SHA-256 hashes (line 59), add validation:

```starlark
    require_hashes = True
    for mod in module_ctx.modules:
        for tag in mod.tags.toolchain:
            if version == None or mod.is_root:
                version = tag.version
                sha256_overrides = dict(tag.sha256)
                require_hashes = tag.require_hashes

    if version == None:
        fail("lean.toolchain(version = ...) is required")

    known = _KNOWN_VERSIONS.get(version, {})
    known_sha256 = known.get("sha256", {})

    for platform in ALL_PLATFORMS:
        sha256 = sha256_overrides.get(platform, known_sha256.get(platform, ""))
        if require_hashes and not sha256:
            fail(
                "SHA-256 hash missing for lean {version} on {platform}. ".format(
                    version = version,
                    platform = platform,
                ) +
                "Provide sha256 = {\"" + platform + "\": \"<hash>\"} in lean.toolchain(), " +
                "or set require_hashes = False for development use only.",
            )
        lean_release(
            name = "lean_" + platform,
            version = version,
            platform = platform,
            sha256 = sha256,
        )
```

- [ ] **Step 3: Verify rules_lean's own MODULE.bazel passes (all hashes present)**

Run: `rivet validate`
Expected: PASS (existing 4.27.0 hashes are all populated)

- [ ] **Step 4: Commit**

```bash
git add lean/extensions.bzl
git commit -m "Enforce SHA-256 verification for lean toolchain downloads

The module extension now fails if any platform hash is empty, preventing
downloads without integrity verification. Set require_hashes = False
in lean.toolchain() for development with unreleased versions.

Implements: SC-002, CC-002
Mitigates: H-002, UCA-002"
```

---

### Task 2: Add CI test for hash enforcement

**Files:**
- Create: `tests/BUILD.bazel`
- Create: `tests/missing_hash/MODULE.bazel`
- Create: `tests/missing_hash/BUILD.bazel`
- Modify: `.github/workflows/ci.yml`

The test verifies that `bazel build` fails with a clear error when a hash is missing.

- [ ] **Step 1: Create a test workspace that deliberately omits a hash**

`tests/missing_hash/MODULE.bazel`:
```starlark
module(name = "test_missing_hash", version = "0.0.0")

bazel_dep(name = "rules_lean", version = "0.1.0")
local_path_override(
    module_name = "rules_lean",
    path = "../..",
)

lean = use_extension("@rules_lean//lean:extensions.bzl", "lean")
lean.toolchain(
    version = "99.0.0",  # Unknown version, no hashes in KNOWN_VERSIONS
    # require_hashes defaults to True — this should fail
)

use_repo(lean, "lean_toolchains")
register_toolchains("@lean_toolchains//:all")
```

`tests/missing_hash/BUILD.bazel`:
```starlark
# Empty — we only need analysis to trigger the extension
```

`tests/missing_hash/.bazelversion`:
```
8.0.0
```

- [ ] **Step 2: Create a test workspace that opts out with require_hashes = False**

`tests/dev_mode/MODULE.bazel`:
```starlark
module(name = "test_dev_mode", version = "0.0.0")

bazel_dep(name = "rules_lean", version = "0.1.0")
local_path_override(
    module_name = "rules_lean",
    path = "../..",
)

lean = use_extension("@rules_lean//lean:extensions.bzl", "lean")
lean.toolchain(
    version = "99.0.0",
    require_hashes = False,  # Explicit opt-out for dev
)

use_repo(lean, "lean_toolchains")
register_toolchains("@lean_toolchains//:all")
```

`tests/dev_mode/BUILD.bazel`:
```starlark
# Empty
```

`tests/dev_mode/.bazelversion`:
```
8.0.0
```

- [ ] **Step 3: Add CI job that runs both tests**

Add to `.github/workflows/ci.yml`:

```yaml
  test-hash-enforcement:
    name: Test SHA-256 enforcement
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: bazelbuild/setup-bazelisk@v3
      - name: Verify missing hash fails
        run: |
          cd tests/missing_hash
          if bazel query '//...' 2>&1; then
            echo "ERROR: should have failed with missing hash"
            exit 1
          else
            bazel query '//...' 2>&1 | grep -q "SHA-256 hash missing"
            echo "PASS: missing hash correctly rejected"
          fi
      - name: Verify dev mode opt-out works
        run: |
          cd tests/dev_mode
          bazel query '//...' 2>&1
          echo "PASS: dev mode opt-out accepted"
```

- [ ] **Step 4: Commit**

```bash
git add tests/ .github/workflows/ci.yml
git commit -m "Add CI tests for SHA-256 hash enforcement

Tests verify:
1. Missing hash for unknown version → fail with clear error
2. require_hashes=False opt-out → analysis succeeds

Verifies: SC-002, CC-002"
```

---

### Task 3: Update rivet artifacts to reflect implementation

**Files:**
- Modify: `artifacts/safety.yaml` (via rivet CLI)

- [ ] **Step 1: Update SC-002 status to implemented**

```bash
rivet modify SC-002 --set-status implemented
```

- [ ] **Step 2: Update CC-002 status to implemented**

```bash
rivet modify CC-002 --set-status implemented
```

- [ ] **Step 3: Update UCA-002 with mitigation note**

```bash
rivet modify UCA-002 --set-field rationale="Mitigated: extension now fail()s when SHA-256 is empty for any platform. Requires explicit require_hashes=False opt-out."
```

- [ ] **Step 4: Validate and check coverage**

```bash
rivet validate
rivet coverage
```

Expected: PASS, 100% coverage, SC-002 and CC-002 show as `implemented`.

- [ ] **Step 5: Commit**

```bash
git add artifacts/safety.yaml
git commit -m "Update STPA artifacts: SC-002, CC-002 implemented

SHA-256 hash enforcement now active in lean/extensions.bzl.
Extension fails on empty hashes; require_hashes=False available
for development.

Artifacts[safety]: SC-002, CC-002 → implemented"
```

---

### Task 4: Push and verify CI

- [ ] **Step 1: Push all commits**

```bash
git push
```

- [ ] **Step 2: Wait for CI and verify all jobs pass**

```bash
gh run list --repo pulseengine/rules_lean --limit 1
gh run view <run_id> --repo pulseengine/rules_lean
```

Expected: All jobs green including new `test-hash-enforcement`.

- [ ] **Step 3: Verify the final state**

```bash
rivet stats
rivet coverage
rivet validate
```

Expected: 46+ artifacts, 100% coverage, 0 warnings, SC-002 and CC-002 status = implemented.
