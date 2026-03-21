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

_LAKEFILE_TEMPLATE = """\
import Lake
open Lake DSL

package «mathlib_fetch»

require mathlib from git
  "https://github.com/leanprover-community/mathlib4.git" @ "{rev}"
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
    rctx.file("lakefile.lean", _LAKEFILE_TEMPLATE.format(rev = rctx.attr.mathlib_rev))

    lean_dir = str(lean.dirname)
    env = {
        "PATH": lean_dir + ":" + rctx.os.environ.get("PATH", ""),
        "HOME": str(rctx.path(".")),
    }

    # Fetch mathlib dependency tree
    result = rctx.execute(
        [str(lake), "update"],
        environment = env,
        timeout = 600,
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
    rctx.execute(["mkdir", "-p", "lib"])
    rctx.execute(["sh", "-c", """
        set -e
        for d in .lake/packages/*/; do
            for lib_dir in "${d}.lake/build/lib/lean" "${d}.lake/build/lib" "${d}build/lib/lean" "${d}build/lib"; do
                if [ -d "$lib_dir" ] && ls "$lib_dir"/ >/dev/null 2>&1; then
                    cp -rn "$lib_dir"/* lib/ 2>/dev/null || true
                    break
                fi
            done
        done
        # Also check root package build
        for lib_dir in .lake/build/lib/lean .lake/build/lib; do
            if [ -d "$lib_dir" ]; then
                cp -rn "$lib_dir"/* lib/ 2>/dev/null || true
                break
            fi
        done
    """])

    # Validate olean consolidation completeness (CC-006)
    # Check Mathlib and its critical transitive dependencies
    result = rctx.execute(["sh", "-c", """
        ok=true
        for pkg in Mathlib Batteries Aesop; do
            if [ ! -d "lib/$pkg" ]; then
                echo "ERROR: lib/$pkg/ not found after olean consolidation"
                ok=false
            else
                count=$(find "lib/$pkg" -name '*.olean' | wc -l)
                echo "$pkg: $count oleans"
                if [ "$count" -lt 10 ]; then
                    echo "ERROR: only $count $pkg oleans found (expected more)"
                    ok=false
                fi
            fi
        done
        mathlib_count=$(find lib/Mathlib -name '*.olean' | wc -l)
        if [ "$mathlib_count" -lt 100 ]; then
            echo "ERROR: only $mathlib_count Mathlib oleans (expected thousands)"
            ok=false
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
