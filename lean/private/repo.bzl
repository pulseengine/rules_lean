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
    # Resolve lean/lake binaries from the host platform toolchain repo
    lean = rctx.path(Label("@" + rctx.attr.lean_repo + "//:bin/lean"))
    lake = rctx.path(Label("@" + rctx.attr.lean_repo + "//:bin/lake"))

    rctx.file("lean-toolchain", "leanprover/lean4:v" + rctx.attr.lean_version + "\n")
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
    rctx.execute(["mkdir", "-p", "lib"])
    rctx.execute(["sh", "-c", """
        for pkg_dir in .lake/packages/*/; do
            for lib_dir in "${pkg_dir}.lake/build/lib" "${pkg_dir}build/lib"; do
                if [ -d "$lib_dir" ]; then
                    cp -r "$lib_dir"/* lib/ 2>/dev/null || true
                fi
            done
        done
    """])

    rctx.file("lib/.marker", "")
    rctx.file("BUILD.bazel", _MATHLIB_BUILD_FILE)

mathlib_repo = repository_rule(
    implementation = _mathlib_repo_impl,
    doc = "Fetches Mathlib4 pre-built oleans via lake.",
    attrs = {
        "lean_repo": attr.string(mandatory = True, doc = "Name of the lean_release repo for the host platform"),
        "lean_version": attr.string(mandatory = True),
        "mathlib_rev": attr.string(mandatory = True, doc = "Mathlib4 git revision or tag"),
    },
)
