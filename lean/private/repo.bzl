"Repository rules for downloading Lean 4 toolchain and Mathlib."

ALL_PLATFORMS = [
    "darwin_aarch64",
    "darwin_x86_64",
    "linux_x86_64",
    "linux_aarch64",
]

_PLATFORM_CONSTRAINTS = {
    "darwin_aarch64": '"@platforms//os:macos", "@platforms//cpu:aarch64"',
    "darwin_x86_64": '"@platforms//os:macos", "@platforms//cpu:x86_64"',
    "linux_x86_64": '"@platforms//os:linux", "@platforms//cpu:x86_64"',
    "linux_aarch64": '"@platforms//os:linux", "@platforms//cpu:aarch64"',
}

# Lean release artifacts use short names for x86_64 platforms
_PLATFORM_ARTIFACT = {
    "darwin_aarch64": "darwin_aarch64",
    "darwin_x86_64": "darwin",
    "linux_x86_64": "linux",
    "linux_aarch64": "linux_aarch64",
}

# ── lean_release ─────────────────────────────────────────────────────────────

_LEAN_BUILD_FILE = """\
load("@rules_lean//lean:toolchain.bzl", "lean_toolchain_info")

package(default_visibility = ["//visibility:public"])

filegroup(name = "lean_bin", srcs = ["bin/lean"])
filegroup(name = "leanc_bin", srcs = ["bin/leanc"])
filegroup(name = "lake_bin", srcs = ["bin/lake"])
filegroup(name = "all_files", srcs = glob(["**"]))

lean_toolchain_info(
    name = "lean_toolchain_info",
    lean = ":lean_bin",
    leanc = ":leanc_bin",
    lake = ":lake_bin",
    all_files = ":all_files",
    version = "{version}",
)
"""

def _lean_release_impl(rctx):
    version = rctx.attr.version
    platform = rctx.attr.platform

    artifact = _PLATFORM_ARTIFACT.get(platform, platform)
    url = "https://github.com/leanprover/lean4/releases/download/v{v}/lean-{v}-{a}.tar.zst".format(
        v = version,
        a = artifact,
    )

    rctx.download_and_extract(
        url = url,
        sha256 = rctx.attr.sha256 if rctx.attr.sha256 else "",
        stripPrefix = "lean-{v}-{a}".format(v = version, a = artifact),
    )

    # Make binaries executable
    for bin_path in ["bin/lean", "bin/leanc", "bin/lake"]:
        rctx.execute(["chmod", "+x", bin_path])

    # Remove macOS quarantine attributes
    if "darwin" in platform:
        rctx.execute(["xattr", "-cr", "."], quiet = True)

    rctx.file("BUILD.bazel", _LEAN_BUILD_FILE.format(version = version))

lean_release = repository_rule(
    implementation = _lean_release_impl,
    doc = "Downloads a Lean 4 release from GitHub.",
    attrs = {
        "version": attr.string(mandatory = True, doc = "Lean 4 version, e.g. '4.27.0'"),
        "platform": attr.string(mandatory = True, values = ALL_PLATFORMS),
        "sha256": attr.string(default = "", doc = "SHA-256 hash of the archive (empty = skip verification)"),
    },
)

# ── lean_toolchains_hub ─────────────────────────────────────────────────────

def _lean_toolchains_hub_impl(rctx):
    lines = ['package(default_visibility = ["//visibility:public"])', ""]
    for p in rctx.attr.platforms:
        lines.append(
            """toolchain(
    name = "{p}",
    exec_compatible_with = [{c}],
    toolchain = "@lean_{p}//:lean_toolchain_info",
    toolchain_type = "@rules_lean//lean:toolchain_type",
)
""".format(p = p, c = _PLATFORM_CONSTRAINTS[p]),
        )

    rctx.file("BUILD.bazel", "\n".join(lines))

lean_toolchains_hub = repository_rule(
    implementation = _lean_toolchains_hub_impl,
    doc = "Hub repository that registers platform-specific Lean 4 toolchains.",
    attrs = {
        "platforms": attr.string_list(mandatory = True),
    },
)

# ── mathlib_repo ─────────────────────────────────────────────────────────────

_MATHLIB_BUILD_FILE = """\
load("@rules_lean//lean:defs.bzl", "lean_prebuilt_library")

package(default_visibility = ["//visibility:public"])

lean_prebuilt_library(
    name = "Mathlib",
    srcs = glob(["lib/**"]),
    path_marker = "lib/.marker",
)
"""

_MATHLIB_GIT_URL = "https://github.com/leanprover-community/mathlib4.git"

# Mathlib is consumed from a LOCAL checkout (see `_mathlib_repo_impl`), not via
# `require ... from git`. Lake's git resolver does a full-history clone (~2 GB)
# with no `--depth` knob, which times out on a cold cache; pointing the require
# at a shallow local checkout avoids that entirely while keeping the checkout's
# `.git` so `lake exe cache get` can still resolve the olean cache key.
_LAKEFILE_TEMPLATE = """\
import Lake
open Lake DSL

package «mathlib_fetch»

require mathlib from "{path}"
"""

def _mathlib_repo_impl(rctx):
    version = rctx.attr.lean_version
    platform = rctx.attr.host_platform
    artifact = _PLATFORM_ARTIFACT.get(platform, platform)

    # Download lean toolchain directly (avoids cross-repo references in bzlmod)
    url = "https://github.com/leanprover/lean4/releases/download/v{v}/lean-{v}-{a}.tar.zst".format(
        v = version,
        a = artifact,
    )
    rctx.download_and_extract(
        url = url,
        output = "_lean_toolchain",
        stripPrefix = "lean-{v}-{a}".format(v = version, a = artifact),
    )
    rctx.execute(["chmod", "+x", "_lean_toolchain/bin/lean", "_lean_toolchain/bin/lake"])

    lean = rctx.path("_lean_toolchain/bin/lean")
    lake = rctx.path("_lean_toolchain/bin/lake")

    rctx.file("lean-toolchain", "leanprover/lean4:v" + version + "\n")

    lean_dir = str(lean.dirname)
    env = {
        "PATH": lean_dir + ":" + rctx.os.environ.get("PATH", ""),
        "HOME": str(rctx.path(".")),
    }

    # ── Shallow pre-clone of mathlib4 at the pinned rev ──────────────────────
    # Fetch ONLY the pinned tag/commit with depth 1 (seconds, not minutes)
    # instead of letting `lake update` full-history-clone the ~2 GB monorepo.
    # The `git init` + `fetch <rev>` + `checkout FETCH_HEAD` form accepts both
    # tags and bare SHAs (unlike `git clone --branch`, which rejects SHAs).
    rev = rctx.attr.mathlib_rev
    src = rctx.path("mathlib4_src")
    init = rctx.execute(["git", "init", "-q", str(src)])
    if init.return_code != 0:
        fail("git init for mathlib4 checkout failed:\n" + init.stderr)

    # An `origin` remote pointing at the GitHub repo is REQUIRED: Mathlib's
    # `lake exe cache get` runs `git remote get-url origin` to derive which
    # repository's olean cache bucket to download from. Without it, cache get
    # aborts ("No such remote 'origin'") and falls back to a multi-hour build.
    remote = rctx.execute(["git", "-C", str(src), "remote", "add", "origin", _MATHLIB_GIT_URL])
    if remote.return_code != 0:
        fail("git remote add origin for mathlib4 failed:\n" + remote.stderr)
    fetch = rctx.execute(
        ["git", "-C", str(src), "fetch", "--depth", "1", "--no-tags", "origin", rev],
        # Defense-in-depth: a single shallow tree is fast, but keep a generous
        # ceiling for slow networks / large single trees.
        timeout = 3600,
        quiet = False,
    )
    if fetch.return_code != 0:
        fail("shallow `git fetch` of mathlib4 @ '{}' failed:\n{}".format(rev, fetch.stderr))
    checkout = rctx.execute(["git", "-C", str(src), "checkout", "-q", "FETCH_HEAD"])
    if checkout.return_code != 0:
        fail("`git checkout FETCH_HEAD` for mathlib4 @ '{}' failed:\n{}".format(rev, checkout.stderr))

    # Sanity-check the checkout looks like mathlib before lake touches it, so a
    # bad/force-moved rev fails here with a clear message rather than deep inside
    # `lake update`. mathlib4 ships a lakefile.lean (older) or lakefile.toml.
    has_lakefile = rctx.path(str(src) + "/lakefile.lean").exists or \
                   rctx.path(str(src) + "/lakefile.toml").exists
    if not has_lakefile:
        fail("mathlib4 @ '{}' has no lakefile.lean/.toml after checkout — bad rev?".format(rev))

    # Point lake at the LOCAL checkout (absolute path). `lake update` now only
    # resolves mathlib's small transitive deps (Batteries, Aesop, ...) from
    # mathlib's own manifest — it never re-clones the monorepo.
    rctx.file("lakefile.lean", _LAKEFILE_TEMPLATE.format(path = str(src)))
    result = rctx.execute(
        [str(lake), "update"],
        environment = env,
        timeout = 3600,
        quiet = False,
    )
    if result.return_code != 0:
        fail("lake update failed:\n" + result.stderr)

    # Download pre-built oleans (fast path)
    result = rctx.execute(
        [str(lake), "exe", "cache", "get"],
        environment = env,
        timeout = 1200,
        quiet = False,
    )
    if result.return_code != 0:
        # Pre-built cache may be unavailable — fall back to building from source
        # buildifier: disable=print
        print("WARNING: pre-built Mathlib cache unavailable, building from source (this will take a long time)...")
        result = rctx.execute(
            [str(lake), "build", "Mathlib"],
            environment = env,
            timeout = 7200,
            quiet = False,
        )
        if result.return_code != 0:
            fail("Failed to build Mathlib:\n" + result.stderr)

    # Consolidate all package oleans into lib/
    # Lake v4 stores oleans at: .lake/packages/<name>/.lake/build/lib/lean/<Module>/...
    # Errors are NOT swallowed: `set -e` aborts on any failure and we check the
    # return code, so a partial/failed copy is attributed to the copy step
    # rather than silently surfacing later as a downstream "missing olean".
    mk = rctx.execute(["mkdir", "-p", "lib"])
    if mk.return_code != 0:
        fail("mkdir lib failed:\n" + mk.stderr)
    consolidate = rctx.execute(["sh", "-c", """
        set -e
        for d in .lake/packages/*/; do
            for lib_dir in "${d}.lake/build/lib/lean" "${d}.lake/build/lib" "${d}build/lib/lean" "${d}build/lib"; do
                if [ -d "$lib_dir" ] && ls "$lib_dir"/ >/dev/null 2>&1; then
                    cp -R "$lib_dir"/. lib/
                    break
                fi
            done
        done
        # Also check root package build
        for lib_dir in .lake/build/lib/lean .lake/build/lib; do
            if [ -d "$lib_dir" ]; then
                cp -R "$lib_dir"/. lib/
                break
            fi
        done
    """])
    if consolidate.return_code != 0:
        fail("olean consolidation copy failed:\n" + consolidate.stdout + "\n" + consolidate.stderr)

    # Validate olean consolidation completeness (CC-006).
    # Data-driven: every olean built under .lake/packages must land in lib/, so
    # a dropped transitive dependency (Qq, ProofWidgets, importGraph, ...) is
    # caught here instead of at proof-build time. Also keep an explicit floor on
    # Mathlib itself as a sanity check against an empty/degenerate fetch.
    result = rctx.execute(["sh", "-c", """
        ok=true
        src_count=$(find .lake/packages -name '*.olean' | wc -l | tr -d ' ')
        dst_count=$(find lib -name '*.olean' | wc -l | tr -d ' ')
        echo "oleans: source=$src_count consolidated=$dst_count"
        if [ "$src_count" -eq 0 ]; then
            echo "ERROR: no oleans found under .lake/packages (fetch/build produced nothing)"
            ok=false
        fi
        if [ "$dst_count" -lt "$src_count" ]; then
            echo "ERROR: consolidated $dst_count oleans but source had $src_count (packages dropped)"
            ok=false
        fi
        if [ ! -d lib/Mathlib ]; then
            echo "ERROR: lib/Mathlib/ not found after consolidation"
            ok=false
        else
            mathlib_count=$(find lib/Mathlib -name '*.olean' | wc -l | tr -d ' ')
            echo "Mathlib: $mathlib_count oleans"
            if [ "$mathlib_count" -lt 100 ]; then
                echo "ERROR: only $mathlib_count Mathlib oleans (expected thousands)"
                ok=false
            fi
        fi
        if [ "$ok" = false ]; then
            exit 1
        fi
    """])
    if result.return_code != 0:
        fail("Mathlib olean consolidation incomplete:\n" + result.stdout + "\n" + result.stderr)

    rctx.file("lib/.marker", "")
    rctx.file("BUILD.bazel", _MATHLIB_BUILD_FILE)

mathlib_repo = repository_rule(
    implementation = _mathlib_repo_impl,
    doc = "Fetches Mathlib4 pre-built oleans via lake.",
    attrs = {
        "lean_version": attr.string(mandatory = True),
        "host_platform": attr.string(mandatory = True, doc = "Host platform for lean download (e.g. darwin_aarch64)"),
        "mathlib_rev": attr.string(mandatory = True, doc = "Mathlib4 git revision or tag"),
    },
)
