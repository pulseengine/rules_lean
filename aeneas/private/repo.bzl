"Repository rules for downloading Aeneas and its Lean support library."

load(
    "//lean/private:mathlib_fetch.bzl",
    "rewrite_git_require_to_local",
    "shallow_fetch_mathlib",
)

ALL_AENEAS_PLATFORMS = [
    "macos_aarch64",
    "macos_x86_64",
    "linux_x86_64",
]

_PLATFORM_CONSTRAINTS = {
    "macos_aarch64": '"@platforms//os:macos", "@platforms//cpu:aarch64"',
    "macos_x86_64": '"@platforms//os:macos", "@platforms//cpu:x86_64"',
    "linux_x86_64": '"@platforms//os:linux", "@platforms//cpu:x86_64"',
}

# Aeneas release artifacts use these names
_PLATFORM_ARTIFACT = {
    "macos_aarch64": "macos-aarch64",
    "macos_x86_64": "macos-x86_64",
    "linux_x86_64": "linux-x86_64",
}

# ── aeneas_release ───────────────────────────────────────────────────────────

_AENEAS_BUILD_FILE = """\
load("@rules_lean//aeneas:toolchain.bzl", "aeneas_toolchain_info")

package(default_visibility = ["//visibility:public"])

filegroup(name = "aeneas_bin", srcs = ["aeneas"])
filegroup(name = "all_files", srcs = glob(["**"]))

aeneas_toolchain_info(
    name = "aeneas_toolchain_info",
    aeneas = ":aeneas_bin",
    all_files = ":all_files",
    lean_lib = "@aeneas_lean_lib//:lib_files",
    lean_lib_path = "",
    version = "{version}",
)
"""

def _aeneas_release_impl(rctx):
    version = rctx.attr.version
    platform = rctx.attr.platform
    artifact = _PLATFORM_ARTIFACT[platform]

    url = "https://github.com/AeneasVerif/aeneas/releases/download/{tag}/aeneas-{a}.tar.gz".format(
        tag = version,
        a = artifact,
    )

    rctx.download_and_extract(
        url = url,
        sha256 = rctx.attr.sha256 if rctx.attr.sha256 else "",
    )

    # Make binary executable (the aeneas tarball ships `aeneas` at the root,
    # with backends/ as a sibling — not under bin/).
    rctx.execute(["chmod", "+x", "aeneas"])

    # Remove macOS quarantine
    if "macos" in platform:
        rctx.execute(["xattr", "-cr", "."], quiet = True)

    rctx.file("BUILD.bazel", _AENEAS_BUILD_FILE.format(version = version))

aeneas_release = repository_rule(
    implementation = _aeneas_release_impl,
    doc = "Downloads an Aeneas release from GitHub.",
    attrs = {
        "version": attr.string(mandatory = True, doc = "Aeneas release tag (e.g. 'build-2026.03.14.003732-...')"),
        "platform": attr.string(mandatory = True, values = ALL_AENEAS_PLATFORMS),
        "sha256": attr.string(default = ""),
    },
)

# ── aeneas_toolchains_hub ────────────────────────────────────────────────────

def _aeneas_toolchains_hub_impl(rctx):
    lines = ['package(default_visibility = ["//visibility:public"])', ""]
    for p in rctx.attr.platforms:
        lines.append(
            """toolchain(
    name = "{p}",
    exec_compatible_with = [{c}],
    toolchain = "@aeneas_{p}//:aeneas_toolchain_info",
    toolchain_type = "@rules_lean//aeneas:toolchain_type",
)
""".format(p = p, c = _PLATFORM_CONSTRAINTS[p]),
        )

    rctx.file("BUILD.bazel", "\n".join(lines))

aeneas_toolchains_hub = repository_rule(
    implementation = _aeneas_toolchains_hub_impl,
    doc = "Hub repository for Aeneas toolchain resolution.",
    attrs = {
        "platforms": attr.string_list(mandatory = True),
    },
)

# ── aeneas_lean_lib ──────────────────────────────────────────────────────────

_LEAN_LIB_BUILD_FILE = """\
load("@rules_lean//lean:defs.bzl", "lean_prebuilt_library")

package(default_visibility = ["//visibility:public"])

filegroup(
    name = "lib_files",
    srcs = glob(["lib/**"]),
)

lean_prebuilt_library(
    name = "Aeneas",
    srcs = glob(["lib/**"]),
    path_marker = "lib/.marker",
)
"""

def _aeneas_lean_lib_impl(rctx):
    version = rctx.attr.lean_version
    platform = rctx.attr.host_platform

    # Platform artifact mapping (same as lean toolchain)
    artifact_map = {
        "darwin_aarch64": "darwin_aarch64",
        "darwin_x86_64": "darwin",
        "linux_x86_64": "linux",
        "linux_aarch64": "linux_aarch64",
    }
    artifact = artifact_map.get(platform, platform)

    # Download lean toolchain directly (avoids cross-repo references in bzlmod)
    lean_url = "https://github.com/leanprover/lean4/releases/download/v{v}/lean-{v}-{a}.tar.zst".format(
        v = version,
        a = artifact,
    )
    rctx.download_and_extract(
        url = lean_url,
        output = "_lean_toolchain",
        stripPrefix = "lean-{v}-{a}".format(v = version, a = artifact),
    )
    rctx.execute(["chmod", "+x", "_lean_toolchain/bin/lean", "_lean_toolchain/bin/lake"])

    lean = rctx.path("_lean_toolchain/bin/lean")
    lake = rctx.path("_lean_toolchain/bin/lake")

    lean_dir = str(lean.dirname)
    env = {
        "PATH": lean_dir + ":" + rctx.os.environ.get("PATH", ""),
        "HOME": str(rctx.path(".")),
    }

    # Download the aeneas lean library source.
    # Reproducibility: an unpinned tarball can change if the tag/rev is moved.
    # Warn loudly when no hash is given (the extension does not yet plumb one —
    # tracked in #7); a consumer can pin it once the digest is known.
    if not rctx.attr.sha256:
        # buildifier: disable=print
        print("WARNING: Aeneas Lean library source (rev '{}') is fetched WITHOUT a sha256 — not hermetic. Provide sha256 to pin it.".format(
            rctx.attr.aeneas_rev,
        ))
    rctx.download_and_extract(
        url = "https://github.com/AeneasVerif/aeneas/archive/{rev}.tar.gz".format(
            rev = rctx.attr.aeneas_rev,
        ),
        sha256 = rctx.attr.sha256 if rctx.attr.sha256 else "",
        stripPrefix = "aeneas-" + rctx.attr.aeneas_rev,
    )

    # Set up the lean library project
    rctx.file("lean-toolchain", "leanprover/lean4:v" + rctx.attr.lean_version + "\n")

    # #7 deep fix: Aeneas's backends/lean/lakefile.lean does
    # `require mathlib from git ... @ "v<lean>"`, which makes `lake update`
    # full-history-clone mathlib4 (~2 GB). Shallow-fetch that exact rev (shared
    # helper, same as @mathlib) and redirect the require at the local checkout,
    # so `lake update` only resolves mathlib's small transitive deps. Aeneas
    # pins mathlib at the matching "v"+lean_version tag.
    mathlib_src = shallow_fetch_mathlib(rctx, "v" + rctx.attr.lean_version)
    rewrite_git_require_to_local(rctx, "backends/lean/lakefile.lean", "mathlib", mathlib_src)

    # Resolve the (now small) remaining transitive deps. The 3600 s ceiling is
    # defense-in-depth; with mathlib local this is no longer the slow step.
    result = rctx.execute(
        [str(lake), "update"],
        environment = env,
        timeout = 3600,
        quiet = False,
        working_directory = "backends/lean",
    )
    if result.return_code != 0:
        fail("lake update for the Aeneas Lean library failed:\n" + result.stderr)

    # Pre-built olean cache (fast path). Non-fatal — `lake build` below rebuilds
    # from source if it is unavailable — but a silently-ignored failure used to
    # mask real problems, so warn loudly.
    result = rctx.execute(
        [str(lake), "exe", "cache", "get"],
        environment = env,
        timeout = 1200,
        quiet = False,
        working_directory = "backends/lean",
    )
    if result.return_code != 0:
        # buildifier: disable=print
        print("WARNING: `lake exe cache get` failed for the Aeneas Lean library; building from source (slower):\n" + result.stderr)

    result = rctx.execute(
        [str(lake), "build", "Aeneas"],
        environment = env,
        timeout = 3600,
        quiet = False,
        working_directory = "backends/lean",
    )
    if result.return_code != 0:
        fail("Failed to build Aeneas Lean library:\n" + result.stderr)

    # Consolidate oleans into lib/. Errors are not swallowed: `set -e` plus a
    # checked return code attribute a failed copy to this step rather than to a
    # downstream "missing olean". `cp -R "$dir"/.` is portable and copies dir
    # contents without a glob that fails when empty.
    mk = rctx.execute(["mkdir", "-p", "lib"])
    if mk.return_code != 0:
        fail("mkdir lib failed:\n" + mk.stderr)
    consolidate = rctx.execute(["sh", "-c", """
        set -e
        # Lake v4 stores oleans under .lake/build/lib/lean/<Module>/...; prefer
        # that level so modules land FLAT in lib/ (lib/Aeneas.olean), which is
        # what `import Aeneas` resolves against the path_marker dir. Copying the
        # outer .../lib/. instead would nest them at lib/lean/Aeneas.olean and
        # break resolution. `break` after the first match picks the right level.
        for pkg_dir in backends/lean/.lake/packages/*/; do
            for lib_dir in "${pkg_dir}.lake/build/lib/lean" "${pkg_dir}.lake/build/lib" "${pkg_dir}build/lib/lean" "${pkg_dir}build/lib"; do
                if [ -d "$lib_dir" ] && ls "$lib_dir"/ >/dev/null 2>&1; then
                    cp -R "$lib_dir"/. lib/
                    break
                fi
            done
        done
        # The Aeneas library itself.
        for lib_dir in backends/lean/.lake/build/lib/lean backends/lean/.lake/build/lib; do
            if [ -d "$lib_dir" ] && ls "$lib_dir"/ >/dev/null 2>&1; then
                cp -R "$lib_dir"/. lib/
                break
            fi
        done
    """])
    if consolidate.return_code != 0:
        fail("Aeneas olean consolidation copy failed:\n" + consolidate.stdout + "\n" + consolidate.stderr)

    rctx.file("lib/.marker", "")
    rctx.file("BUILD.bazel", _LEAN_LIB_BUILD_FILE)

aeneas_lean_lib = repository_rule(
    implementation = _aeneas_lean_lib_impl,
    doc = "Builds the Aeneas Lean support library from source.",
    attrs = {
        "lean_version": attr.string(mandatory = True),
        "host_platform": attr.string(mandatory = True),
        "aeneas_rev": attr.string(mandatory = True, doc = "Git commit hash for aeneas source"),
        "sha256": attr.string(default = ""),
    },
)
